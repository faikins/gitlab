#!/usr/bin/env python3
"""
ecs_morning_health.py

Morning ECS service health summary for a single AWS region.

What it does:
- Lists ECS clusters
- Lists services per cluster
- Describes each service
- Prints a GREEN / AMBER / RED / GRAY summary per service

Health rules:
- GRAY: desiredCount == 0
- RED: runningCount == 0 and desiredCount > 0, OR deployment rolloutState == FAILED
- AMBER: runningCount < desiredCount, or pendingCount > 0, or rolloutState == IN_PROGRESS
- GREEN: everything else

Optional:
- Filter to Fargate services only (includes capacity-provider-based Fargate)
- Restrict to selected clusters
"""

from __future__ import annotations

import argparse
import csv
import sys
from dataclasses import dataclass
from typing import Iterable, List, Optional

import boto3
from botocore.exceptions import BotoCoreError, ClientError


STATUS_GREEN = "GREEN"
STATUS_AMBER = "AMBER"
STATUS_RED = "RED"
STATUS_GRAY = "GRAY"

# Max display widths for long free-text columns
MAX_TASKDEF_WIDTH = 40
MAX_SUMMARY_WIDTH = 55


@dataclass
class ServiceHealth:
    cluster_name: str
    service_name: str
    launch_type: str
    desired_count: int
    running_count: int
    pending_count: int
    task_definition: str
    rollout_state: str
    rollout_reason: str
    last_deployed: str
    status: str
    summary: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Print ECS morning health summary by service."
    )
    parser.add_argument(
        "--region",
        default="us-east-1",
        help="AWS region to inspect. Default: us-east-1",
    )
    parser.add_argument(
        "--clusters",
        nargs="*",
        help=(
            "Optional list of cluster names to inspect. "
            "If omitted, all clusters in the region are used."
        ),
    )
    parser.add_argument(
        "--fargate-only",
        action="store_true",
        help=(
            "Only include Fargate services. "
            "Matches both explicit launchType=FARGATE and capacity-provider-based Fargate services."
        ),
    )
    parser.add_argument(
        "--profile",
        help="Optional AWS CLI profile name.",
    )
    parser.add_argument(
        "--csv",
        action="store_true",
        help="Output results as CSV instead of a formatted table.",
    )
    return parser.parse_args()


def build_session(profile: Optional[str], region: str):
    if profile:
        return boto3.Session(profile_name=profile, region_name=region)
    return boto3.Session(region_name=region)


def get_ecs_client(session):
    return session.client("ecs")


def paginate_cluster_arns(ecs_client) -> List[str]:
    cluster_arns: List[str] = []
    paginator = ecs_client.get_paginator("list_clusters")
    for page in paginator.paginate():
        cluster_arns.extend(page.get("clusterArns", []))
    return cluster_arns


def paginate_service_arns(ecs_client, cluster_name: str) -> List[str]:
    service_arns: List[str] = []
    paginator = ecs_client.get_paginator("list_services")
    for page in paginator.paginate(cluster=cluster_name):
        service_arns.extend(page.get("serviceArns", []))
    return service_arns


def chunked(items: List[str], size: int) -> Iterable[List[str]]:
    for i in range(0, len(items), size):
        yield items[i : i + size]


def short_task_definition(task_definition_arn: Optional[str]) -> str:
    """Return the short form (family:revision) from a full task definition ARN.

    Returns an empty string for None or empty input rather than raising.
    """
    if not task_definition_arn:
        return ""
    return task_definition_arn.split("/")[-1]


def is_fargate_service(service: dict) -> bool:
    """Return True for services running on Fargate.

    Handles both explicit launchType='FARGATE' and services that use a
    FARGATE or FARGATE_SPOT capacity provider strategy (where launchType
    may be absent or empty).
    """
    if service.get("launchType") == "FARGATE":
        return True
    providers = service.get("capacityProviderStrategy", [])
    return any(
        p.get("capacityProvider", "").startswith("FARGATE")
        for p in providers
    )


def extract_primary_deployment(service: dict) -> dict:
    deployments = service.get("deployments", [])
    for dep in deployments:
        if dep.get("status") == "PRIMARY":
            return dep
    return deployments[0] if deployments else {}


def classify_service(service: dict, cluster_name: str) -> ServiceHealth:
    service_name = service.get("serviceName", "")
    desired_count = service.get("desiredCount", 0)
    running_count = service.get("runningCount", 0)
    pending_count = service.get("pendingCount", 0)
    task_definition = short_task_definition(service.get("taskDefinition"))

    # Derive a human-readable launch type label
    if service.get("launchType"):
        launch_type = service["launchType"]
    elif any(
        p.get("capacityProvider", "").startswith("FARGATE")
        for p in service.get("capacityProviderStrategy", [])
    ):
        launch_type = "FARGATE(CP)"
    else:
        launch_type = "UNKNOWN"

    primary = extract_primary_deployment(service)
    rollout_state = primary.get("rolloutState", "")
    rollout_reason = primary.get("rolloutStateReason", "")
    created_at = primary.get("createdAt")
    last_deployed = created_at.strftime("%Y-%m-%d %H:%M UTC") if created_at else "-"

    # --- Base classification ---
    if desired_count == 0:
        status = STATUS_GRAY
        summary = "Service intentionally stopped"
    elif running_count == 0 and desired_count > 0:
        status = STATUS_RED
        summary = "No running tasks but desired count is greater than zero"
    elif running_count < desired_count:
        status = STATUS_AMBER
        summary = "Running tasks below desired count"
    elif pending_count > 0:
        status = STATUS_AMBER
        summary = "Tasks pending"
    else:
        status = STATUS_GREEN
        summary = "Healthy"

    # --- Deployment rollout overrides ---
    # FAILED always escalates to RED regardless of task counts
    if rollout_state and rollout_state.upper() == "FAILED":
        status = STATUS_RED
        summary = f"Deployment failed: {rollout_reason or 'No rollout reason provided'}"

    # IN_PROGRESS escalates to AMBER only if we would otherwise call it GREEN
    # (already AMBER/RED conditions take precedence)
    elif rollout_state and rollout_state.upper() == "IN_PROGRESS" and status == STATUS_GREEN:
        status = STATUS_AMBER
        summary = "Deployment in progress"

    return ServiceHealth(
        cluster_name=cluster_name,
        service_name=service_name,
        launch_type=launch_type,
        desired_count=desired_count,
        running_count=running_count,
        pending_count=pending_count,
        task_definition=task_definition,
        rollout_state=rollout_state,
        rollout_reason=rollout_reason,
        last_deployed=last_deployed,
        status=status,
        summary=summary,
    )


def describe_services_for_cluster(
    ecs_client,
    cluster_name: str,
    fargate_only: bool,
) -> List[ServiceHealth]:
    service_arns = paginate_service_arns(ecs_client, cluster_name)

    if not service_arns:
        print(f"  (cluster '{cluster_name}': no services found)", file=sys.stderr)
        return []

    results: List[ServiceHealth] = []

    for batch in chunked(service_arns, 10):
        try:
            response = ecs_client.describe_services(cluster=cluster_name, services=batch)
        except (ClientError, BotoCoreError) as exc:
            print(
                f"ERROR describing services for cluster={cluster_name}: {exc}",
                file=sys.stderr,
            )
            continue

        services = response.get("services", [])
        failures = response.get("failures", [])
        for failure in failures:
            print(
                f"WARNING failed to describe service in cluster={cluster_name}: {failure}",
                file=sys.stderr,
            )

        for service in services:
            if fargate_only and not is_fargate_service(service):
                continue
            results.append(classify_service(service, cluster_name))

    return results


def resolve_cluster_names(
    ecs_client,
    requested_clusters: Optional[List[str]],
) -> List[str]:
    """Return cluster names to inspect.

    When the caller specifies clusters explicitly, validate each name
    against what actually exists in the region and warn on mismatches.
    """
    all_arns = paginate_cluster_arns(ecs_client)
    valid_names = {arn.split("/")[-1] for arn in all_arns}

    if requested_clusters:
        for name in requested_clusters:
            if name not in valid_names:
                print(
                    f"WARNING: cluster '{name}' not found in this region — skipping.",
                    file=sys.stderr,
                )
        # Return only validated names in the original order
        return [c for c in requested_clusters if c in valid_names]

    return sorted(valid_names)


def truncate(value: str, max_width: int) -> str:
    """Truncate a string and append an ellipsis if it exceeds max_width."""
    if len(value) <= max_width:
        return value
    return value[: max_width - 1] + "…"


def print_csv(rows: List[ServiceHealth]) -> None:
    writer = csv.writer(sys.stdout)
    writer.writerow([
        "status", "cluster", "service", "launch_type",
        "running", "desired", "pending", "task_definition",
        "rollout_state", "last_deployed", "summary",
    ])
    for row in rows:
        writer.writerow([
            row.status, row.cluster_name, row.service_name, row.launch_type,
            row.running_count, row.desired_count, row.pending_count,
            row.task_definition, row.rollout_state or "",
            row.last_deployed, row.summary,
        ])


def print_summary_table(rows: List[ServiceHealth]) -> None:
    if not rows:
        print("No services found.")
        return

    headers = [
        "STATUS",
        "CLUSTER",
        "SERVICE",
        "LAUNCH",
        "RUNNING",
        "DESIRED",
        "PENDING",
        "TASKDEF",
        "ROLLOUT",
        "LAST DEPLOYED",
        "SUMMARY",
    ]

    data = []
    for row in rows:
        data.append(
            [
                row.status,
                row.cluster_name,
                row.service_name,
                row.launch_type,
                str(row.running_count),
                str(row.desired_count),
                str(row.pending_count),
                truncate(row.task_definition, MAX_TASKDEF_WIDTH),
                row.rollout_state or "-",
                row.last_deployed,
                truncate(row.summary, MAX_SUMMARY_WIDTH),
            ]
        )

    widths = [len(h) for h in headers]
    for record in data:
        for i, value in enumerate(record):
            widths[i] = max(widths[i], len(value))

    def fmt_line(values: List[str]) -> str:
        return "  ".join(value.ljust(widths[i]) for i, value in enumerate(values))

    print(fmt_line(headers))
    print(fmt_line(["-" * width for width in widths]))

    for record in data:
        print(fmt_line(record))


def print_totals(rows: List[ServiceHealth]) -> None:
    green = sum(1 for r in rows if r.status == STATUS_GREEN)
    amber = sum(1 for r in rows if r.status == STATUS_AMBER)
    red = sum(1 for r in rows if r.status == STATUS_RED)
    gray = sum(1 for r in rows if r.status == STATUS_GRAY)

    print("\nTotals")
    print("------")
    print(f"GREEN: {green}")
    print(f"AMBER: {amber}")
    print(f"RED:   {red}")
    print(f"GRAY:  {gray}")
    print(f"TOTAL: {len(rows)}")


def main() -> int:
    args = parse_args()
    session = build_session(args.profile, args.region)
    ecs_client = get_ecs_client(session)

    try:
        cluster_names = resolve_cluster_names(ecs_client, args.clusters)
    except (ClientError, BotoCoreError) as exc:
        print(f"ERROR listing ECS clusters: {exc}", file=sys.stderr)
        return 1

    if not cluster_names:
        print("No ECS clusters found.")
        return 0

    all_rows: List[ServiceHealth] = []
    for cluster_name in cluster_names:
        try:
            rows = describe_services_for_cluster(
                ecs_client=ecs_client,
                cluster_name=cluster_name,
                fargate_only=args.fargate_only,
            )
            all_rows.extend(rows)
        except (ClientError, BotoCoreError) as exc:
            print(
                f"ERROR processing cluster={cluster_name}: {exc}",
                file=sys.stderr,
            )

    all_rows.sort(
        key=lambda x: (
            {"RED": 0, "AMBER": 1, "GRAY": 2, "GREEN": 3}.get(x.status, 9),
            x.cluster_name,
            x.service_name,
        )
    )

    if not args.csv:
        print(f"\nECS Morning Health Summary | region={args.region}\n")
    if args.csv:
        print_csv(all_rows)
    else:
        print_summary_table(all_rows)
        print_totals(all_rows)

    has_red = any(r.status == STATUS_RED for r in all_rows)
    return 2 if has_red else 0


if __name__ == "__main__":
    raise SystemExit(main())
