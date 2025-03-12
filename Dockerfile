# Use the Alpine-based .NET 6 runtime image
FROM mcr.microsoft.com/dotnet/aspnet:6.0-alpine

# Install supervisor, rclone and bash (if needed)
RUN apk update && \
    apk add --no-cache supervisor rclone bash

WORKDIR /app

# Copy the published .NET application files into the container.
# Assumes your published app is in the "publish" directory.
COPY ./publish/ /app/

# Copy the rclone sync script and ensure it's executable
COPY rclone-sync.sh /app/rclone-sync.sh
RUN chmod +x /app/rclone-sync.sh

# Copy the Supervisor configuration
COPY supervisord.conf /etc/supervisord.conf

# Expose port 80 (if your .NET app listens on it)
EXPOSE 80

# Start Supervisor to run both the .NET app and rclone sync script
CMD ["supervisord", "-c", "/etc/supervisord.conf"]
