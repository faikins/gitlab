using System;
using System.IO;
using System.Threading;

namespace LogWriter
{
    class Program
    {
        static void Main(string[] args)
        {
            // Ensure the logs directory exists
            Directory.CreateDirectory("/app/logs");
            Console.WriteLine("LogWriter started.");

            // Write a log entry every minute
            while (true)
            {
                string logFile = $"/app/logs/log_{DateTime.Now:yyyyMMdd}.txt";
                string logEntry = $"{DateTime.Now}: Log entry from .NET app";
                File.AppendAllText(logFile, logEntry + Environment.NewLine);
                Console.WriteLine(logEntry);
                Thread.Sleep(60000); // Wait 60 seconds
            }
        }
    }
}
