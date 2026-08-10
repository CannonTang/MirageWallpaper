//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

using System.Collections.Concurrent;
using System.Text.Json;
using MirageSteamService;
using SteamKit2;
using SteamKit2.Authentication;

var writer = new ProtocolWriter();
await using var session = new SteamSession(writer);
var downloader = new WorkshopDownloader(session, writer);
var downloads = new ConcurrentDictionary<string, DownloadOperation>();
CancellationTokenSource? authenticationCancellation = null;
Task? authenticationTask = null;
var jsonOptions = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
var running = true;

while (running)
{
    var line = await Console.In.ReadLineAsync().ConfigureAwait(false);
    if (line == null) break;
    ServiceCommand? command;
    try
    {
        command = JsonSerializer.Deserialize<ServiceCommand>(line, jsonOptions);
    }
    catch (Exception error)
    {
        writer.Response(null, false, error.Message);
        continue;
    }
    if (command == null || string.IsNullOrWhiteSpace(command.Command))
    {
        writer.Response(command?.RequestId, false, "Invalid command.", "INVALID_COMMAND");
        continue;
    }

    switch (command.Command)
    {
        case "hello":
            writer.Send(new { type = "hello", requestId = command.RequestId, version = "1.0.0", maxConcurrentDownloads = 3 });
            break;
        case "ping":
            writer.Send(new { type = "pong", requestId = command.RequestId });
            break;
        case "restoreSession":
            if (string.IsNullOrWhiteSpace(command.Username) || string.IsNullOrWhiteSpace(command.RefreshToken))
            {
                writer.AuthState("loggedOut");
                writer.Response(command.RequestId, false, "No persisted Steam session was provided.", "NO_SAVED_SESSION");
                break;
            }
            await StopAuthenticationAsync(session, authenticationCancellation, authenticationTask).ConfigureAwait(false);
            authenticationCancellation = new CancellationTokenSource();
            var restoreCancellation = authenticationCancellation;
            writer.Response(command.RequestId, true);
            authenticationTask = RunAuthenticationAsync(
                () => session.LoginWithRefreshTokenAsync(command.Username, command.RefreshToken, restoreCancellation.Token),
                writer,
                restoreCancellation.Token);
            break;
        case "loginPassword":
            if (string.IsNullOrWhiteSpace(command.Username) || string.IsNullOrWhiteSpace(command.Password))
            {
                writer.Response(command.RequestId, false, "Steam username and password are required.", "MISSING_CREDENTIALS");
                break;
            }
            await StopAuthenticationAsync(session, authenticationCancellation, authenticationTask).ConfigureAwait(false);
            authenticationCancellation = new CancellationTokenSource();
            var passwordCancellation = authenticationCancellation;
            writer.Response(command.RequestId, true);
            authenticationTask = RunAuthenticationAsync(
                () => session.LoginWithPasswordAsync(command.Username, command.Password, command.GuardData, passwordCancellation.Token),
                writer,
                passwordCancellation.Token);
            break;
        case "loginQr":
            await StopAuthenticationAsync(session, authenticationCancellation, authenticationTask).ConfigureAwait(false);
            authenticationCancellation = new CancellationTokenSource();
            var qrCancellation = authenticationCancellation;
            writer.Response(command.RequestId, true);
            authenticationTask = RunAuthenticationAsync(
                () => session.LoginWithQrAsync(qrCancellation.Token),
                writer,
                qrCancellation.Token);
            break;
        case "submitChallenge":
            writer.Response(command.RequestId, !string.IsNullOrWhiteSpace(command.Code) && session.SubmitChallenge(command.Code), "No authentication challenge is waiting for a code.", "NO_AUTH_CHALLENGE");
            break;
        case "cancelLogin":
            await StopAuthenticationAsync(session, authenticationCancellation, authenticationTask).ConfigureAwait(false);
            authenticationCancellation = null;
            authenticationTask = null;
            writer.AuthState(session.IsLoggedIn ? "loggedIn" : "loggedOut", session.IsLoggedIn ? session.AccountName : null);
            writer.Response(command.RequestId, true);
            break;
        case "download":
            if (!session.IsLoggedIn)
            {
                writer.Response(command.RequestId, false, "The Steam session is not authenticated.", "NOT_AUTHENTICATED");
                break;
            }
            if (string.IsNullOrWhiteSpace(command.TaskId) || string.IsNullOrWhiteSpace(command.WorkshopId) || string.IsNullOrWhiteSpace(command.OutputRoot) || !ulong.TryParse(command.WorkshopId, out var workshopId))
            {
                writer.Response(command.RequestId, false, "Download parameters are invalid.", "INVALID_DOWNLOAD");
                break;
            }
            if (downloads.ContainsKey(command.TaskId))
            {
                writer.Response(command.RequestId, false, "The download task already exists.", "DUPLICATE_DOWNLOAD");
                break;
            }
            var downloadCancellation = new CancellationTokenSource();
            var downloadOperation = new DownloadOperation(downloadCancellation);
            if (!downloads.TryAdd(command.TaskId, downloadOperation))
            {
                downloadOperation.Dispose();
                writer.Response(command.RequestId, false, "The download task could not be created.", "DOWNLOAD_CREATE_FAILED");
                break;
            }
            writer.Response(command.RequestId, true);
            downloadOperation.Task = RunDownloadAsync(command.TaskId, workshopId, command.OutputRoot, downloadOperation, downloads, downloader, writer);
            break;
        case "cancelDownload":
            if (!string.IsNullOrWhiteSpace(command.TaskId) && downloads.TryGetValue(command.TaskId, out var download))
            {
                download.Cancel();
                writer.Response(command.RequestId, true);
            }
            else
            {
                writer.Response(command.RequestId, false, "The download task does not exist.", "DOWNLOAD_NOT_FOUND");
            }
            break;
        case "logout":
            await StopAuthenticationAsync(session, authenticationCancellation, authenticationTask).ConfigureAwait(false);
            authenticationCancellation = null;
            authenticationTask = null;
            await StopDownloadsAsync(downloads).ConfigureAwait(false);
            session.Logout();
            writer.Response(command.RequestId, true);
            break;
        case "shutdown":
            writer.Response(command.RequestId, true);
            running = false;
            break;
        default:
            writer.Response(command.RequestId, false, "Unsupported command.", "UNSUPPORTED_COMMAND");
            break;
    }
}

await StopAuthenticationAsync(session, authenticationCancellation, authenticationTask).ConfigureAwait(false);
await StopDownloadsAsync(downloads).ConfigureAwait(false);

static async Task RunAuthenticationAsync(Func<Task> action, ProtocolWriter writer, CancellationToken cancellationToken)
{
    try
    {
        await action().ConfigureAwait(false);
    }
    catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
    {
        writer.AuthState("loggedOut", message: "Authentication was cancelled.", errorCode: "AUTH_CANCELLED");
    }
    catch (OperationCanceledException error)
    {
        writer.AuthState("failed", message: UserMessage(error), errorCode: "AUTH_SERVICE_TEMPORARY");
    }
    catch (AsyncJobFailedException)
    {
        writer.AuthState("failed", message: "Steam authentication service did not complete the request.", errorCode: "AUTH_SERVICE_TEMPORARY");
    }
    catch (AuthenticationException error)
    {
        writer.AuthState("failed", message: $"{error.Message}: {error.Result}", errorCode: "AUTH_FAILED");
    }
    catch (Exception error)
    {
        writer.AuthState("failed", message: UserMessage(error), errorCode: ErrorCode(error));
    }
}

static async Task RunDownloadAsync(string taskId, ulong workshopId, string outputRoot, DownloadOperation operation, ConcurrentDictionary<string, DownloadOperation> downloads, WorkshopDownloader downloader, ProtocolWriter writer)
{
    try
    {
        var result = await downloader.DownloadAsync(taskId, workshopId, outputRoot, operation.Token).ConfigureAwait(false);
        writer.DownloadState(taskId, "completed", result.TotalBytes, result.TotalBytes, outputPath: result.OutputPath);
    }
    catch (OperationCanceledException) when (operation.Token.IsCancellationRequested)
    {
        writer.DownloadState(taskId, "cancelled", message: "Download was cancelled.", errorCode: "DOWNLOAD_CANCELLED");
    }
    catch (OperationCanceledException error)
    {
        writer.DownloadState(taskId, "failed", message: UserMessage(error), errorCode: "DOWNLOAD_INTERRUPTED");
    }
    catch (Exception error)
    {
        writer.DownloadState(taskId, "failed", message: UserMessage(error), errorCode: ErrorCode(error));
    }
    finally
    {
        downloads.TryRemove(taskId, out _);
        operation.Dispose();
    }
}

static async Task StopAuthenticationAsync(SteamSession session, CancellationTokenSource? cancellation, Task? task)
{
    var wasRunning = task is { IsCompleted: false };
    session.CancelAuthentication();
    try { cancellation?.Cancel(); } catch (AggregateException) { }
    if (task != null)
    {
        try { await task.ConfigureAwait(false); } catch { }
    }
    if (wasRunning && !session.IsLoggedIn)
    {
        try { await session.ResetConnectionAsync().ConfigureAwait(false); } catch { }
    }
    cancellation?.Dispose();
}

static async Task StopDownloadsAsync(ConcurrentDictionary<string, DownloadOperation> downloads)
{
    var active = downloads.Values.ToArray();
    foreach (var operation in active) operation.Cancel();
    if (active.Length == 0) return;
    try { await Task.WhenAll(active.Select(operation => operation.Task)).ConfigureAwait(false); } catch { }
}

static string UserMessage(Exception error)
{
    var current = error;
    while (current.InnerException != null && current is AggregateException or IOException) current = current.InnerException;
    return current.Message;
}

static string ErrorCode(Exception error)
{
    var current = error;
    while (current.InnerException != null && current is AggregateException or IOException) current = current.InnerException;
    return current is ServiceException failure ? failure.Code : "UNEXPECTED_ERROR";
}

internal sealed class DownloadOperation : IDisposable
{
    private readonly CancellationTokenSource cancellation;
    private readonly object gate = new();
    private bool disposed;

    public DownloadOperation(CancellationTokenSource cancellation)
    {
        this.cancellation = cancellation;
    }

    public CancellationToken Token => cancellation.Token;
    public Task Task { get; set; } = Task.CompletedTask;

    public void Cancel()
    {
        lock (gate)
        {
            if (!disposed)
            {
                try { cancellation.Cancel(); } catch (AggregateException) { }
            }
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) return;
            disposed = true;
            cancellation.Dispose();
        }
    }
}
