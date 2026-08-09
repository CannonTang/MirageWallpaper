//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

using System.Collections.Concurrent;
using System.Security.Cryptography;
using SteamKit2;
using SteamKit2.CDN;
using SteamKit2.Internal;

namespace MirageSteamService;

internal sealed class WorkshopDownloader
{
    private static readonly SemaphoreSlim GlobalChunkSlots = new(8, 8);
    private readonly SteamSession session;
    private readonly ProtocolWriter writer;

    public WorkshopDownloader(SteamSession session, ProtocolWriter writer)
    {
        this.session = session;
        this.writer = writer;
    }

    public async Task DownloadAsync(string taskId, ulong workshopId, string outputRoot, CancellationToken cancellationToken)
    {
        if (!OperatingSystem.IsMacOS()) throw new PlatformNotSupportedException();
        writer.DownloadState(taskId, "resolving");
        var detailsRequest = new CPublishedFile_GetDetails_Request { appid = SteamSession.AppId, includechildren = true };
        detailsRequest.publishedfileids.Add(workshopId);
        cancellationToken.ThrowIfCancellationRequested();
        var detailsResponse = await session.PublishedFiles.GetDetails(detailsRequest).ToTask().WaitAsync(cancellationToken).ConfigureAwait(false);
        var details = detailsResponse.Body.publishedfiledetails.FirstOrDefault(item => item.publishedfileid == workshopId);
        if (details == null || details.result != (uint)EResult.OK) throw new ServiceException("WORKSHOP_DETAILS_UNAVAILABLE", "Steam returned no valid Workshop item details.");
        if (details.consumer_appid != SteamSession.AppId) throw new ServiceException("WRONG_APP", "The Workshop item does not belong to Wallpaper Engine.");
        if (details.hcontent_file == 0) throw new ServiceException("CONTENT_MANIFEST_MISSING", "The Workshop item has no content manifest.");

        var appInfo = await session.GetAppInfoAsync(cancellationToken).ConfigureAwait(false);
        var depotId = appInfo.KeyValues["depots"]["workshopdepot"].AsUnsignedInteger();
        if (depotId == 0) throw new ServiceException("WORKSHOP_DEPOT_MISSING", "Wallpaper Engine Workshop depot could not be resolved.");
        cancellationToken.ThrowIfCancellationRequested();
        var depotKeyResult = await session.Apps.GetDepotDecryptionKey(depotId, SteamSession.AppId).ToTask().WaitAsync(cancellationToken).ConfigureAwait(false);
        if (depotKeyResult.Result != EResult.OK) throw new ServiceException("CONTENT_ACCESS_DENIED", depotKeyResult.Result.ToString());
        var requestCode = await session.Content.GetManifestRequestCode(depotId, SteamSession.AppId, details.hcontent_file, "public").WaitAsync(cancellationToken).ConfigureAwait(false);
        if (requestCode == 0) throw new ServiceException("MANIFEST_ACCESS_DENIED", "Steam returned no manifest request code.");

        using var cdn = new Client(session.Client);
        using var cancellationRegistration = cancellationToken.Register(cdn.Dispose);
        var serverInfo = await session.GetDownloadServerAsync(depotId, 0, cancellationToken).ConfigureAwait(false);
        var manifest = await cdn.DownloadManifestAsync(depotId, details.hcontent_file, requestCode, serverInfo.Server, depotKeyResult.DepotKey, cdnAuthToken: serverInfo.Token).WaitAsync(cancellationToken).ConfigureAwait(false);
        if (manifest.Files == null || manifest.Files.Count == 0) throw new ServiceException("EMPTY_MANIFEST", "The Workshop content manifest is empty.");

        var root = Path.GetFullPath(outputRoot);
        Directory.CreateDirectory(root);
        var stagingParent = Path.Combine(root, ".staging");
        var staging = Path.Combine(stagingParent, workshopId.ToString());
        var final = Path.Combine(root, workshopId.ToString());
        var backup = final + ".previous";
        Directory.CreateDirectory(stagingParent);
        cancellationToken.ThrowIfCancellationRequested();
        if (!Directory.Exists(final) && Directory.Exists(backup)) Directory.Move(backup, final);
        if (!Directory.Exists(staging))
        {
            if (Directory.Exists(final)) CopyDirectory(final, staging, cancellationToken);
            else Directory.CreateDirectory(staging);
        }
        ValidateNoLinks(staging, cancellationToken);

        var files = manifest.Files.Where(file => !file.Flags.HasFlag(EDepotFileFlag.Directory)).ToArray();
        var resolvedFiles = new List<(DepotManifest.FileData File, string Path)>();
        foreach (var file in files)
        {
            if (file.Flags.HasFlag(EDepotFileFlag.Symlink)) throw new ServiceException("UNSUPPORTED_SYMLINK", "The content manifest contains a symbolic link.");
            resolvedFiles.Add((file, ResolveContainedPath(staging, file.FileName)));
        }

        var needed = new ConcurrentQueue<(DepotManifest.FileData File, DepotManifest.ChunkData Chunk, string Path)>();
        long totalCompressed = 0;
        long reusableCompressed = 0;
        foreach (var entry in resolvedFiles)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Directory.CreateDirectory(Path.GetDirectoryName(entry.Path)!);
            var existingLength = File.Exists(entry.Path) ? new FileInfo(entry.Path).Length : -1;
            if (existingLength != (long)entry.File.TotalSize)
            {
                using var resize = new FileStream(entry.Path, FileMode.OpenOrCreate, FileAccess.Write, FileShare.ReadWrite);
                resize.SetLength((long)entry.File.TotalSize);
            }
            using var validationStream = new FileStream(entry.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            foreach (var chunk in entry.File.Chunks.OrderBy(chunk => chunk.Offset))
            {
                totalCompressed += chunk.CompressedLength;
                if (IsChunkValid(validationStream, chunk)) reusableCompressed += chunk.CompressedLength;
                else needed.Enqueue((entry.File, chunk, entry.Path));
            }
        }

        using var progress = new DownloadProgressTracker(writer, taskId);
        progress.Start(totalCompressed, reusableCompressed);
        var workers = Enumerable.Range(0, Math.Min(4, Math.Max(1, needed.Count)))
            .Select(index => RunWorkerAsync(index, depotId, depotKeyResult.DepotKey, needed, progress, cancellationToken))
            .ToArray();
        await Task.WhenAll(workers).ConfigureAwait(false);
        progress.Stop();

        writer.DownloadState(taskId, "validating", totalCompressed, totalCompressed);
        ValidateNoLinks(staging, cancellationToken);
        foreach (var entry in resolvedFiles)
        {
            cancellationToken.ThrowIfCancellationRequested();
            using var stream = new FileStream(entry.Path, FileMode.Open, FileAccess.Read, FileShare.Read);
            foreach (var chunk in entry.File.Chunks)
            {
                if (!IsChunkValid(stream, chunk)) throw new ServiceException("VALIDATION_FAILED", entry.File.FileName);
            }
            if (entry.File.Flags.HasFlag(EDepotFileFlag.Executable))
            {
                var mode = File.GetUnixFileMode(entry.Path);
                File.SetUnixFileMode(entry.Path, mode | UnixFileMode.UserExecute | UnixFileMode.GroupExecute | UnixFileMode.OtherExecute);
            }
        }

        RemoveUnlistedFiles(staging, resolvedFiles.Select(item => item.Path).ToHashSet(StringComparer.Ordinal));
        var project = Path.Combine(staging, "project.json");
        if (!File.Exists(project)) throw new ServiceException("PROJECT_JSON_MISSING", "Downloaded content does not contain project.json.");
        Install(staging, final, cancellationToken);
        writer.DownloadState(taskId, "completed", totalCompressed, totalCompressed, outputPath: final);
    }

    private async Task RunWorkerAsync(int workerIndex, uint depotId, byte[] depotKey, ConcurrentQueue<(DepotManifest.FileData File, DepotManifest.ChunkData Chunk, string Path)> queue, DownloadProgressTracker progress, CancellationToken cancellationToken)
    {
        using var cdn = new Client(session.Client);
        using var cancellationRegistration = cancellationToken.Register(cdn.Dispose);
        while (queue.TryDequeue(out var work))
        {
            cancellationToken.ThrowIfCancellationRequested();
            await GlobalChunkSlots.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                Exception? lastError = null;
                for (var attempt = 0; attempt < 4; attempt++)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    try
                    {
                        var server = await session.GetDownloadServerAsync(depotId, workerIndex + attempt, cancellationToken).ConfigureAwait(false);
                        var buffer = new byte[work.Chunk.UncompressedLength];
                        using var transfer = progress.BeginTransfer(work.Chunk.CompressedLength);
                        DownloadContext.Current.Value = transfer;
                        try
                        {
                            var written = await cdn.DownloadDepotChunkAsync(depotId, work.Chunk, server.Server, buffer, depotKey, cdnAuthToken: server.Token).WaitAsync(cancellationToken).ConfigureAwait(false);
                            using var handle = File.OpenHandle(work.Path, FileMode.Open, FileAccess.Write, FileShare.ReadWrite, FileOptions.Asynchronous | FileOptions.RandomAccess);
                            await RandomAccess.WriteAsync(handle, buffer.AsMemory(0, written), (long)work.Chunk.Offset, cancellationToken).ConfigureAwait(false);
                            transfer.Complete();
                            lastError = null;
                            break;
                        }
                        finally
                        {
                            DownloadContext.Current.Value = null;
                        }
                    }
                    catch (OperationCanceledException) { throw; }
                    catch (Exception error)
                    {
                        lastError = error;
                        await Task.Delay(TimeSpan.FromMilliseconds(300 * (attempt + 1)), cancellationToken).ConfigureAwait(false);
                    }
                }
                if (lastError != null) throw new ServiceException("CHUNK_DOWNLOAD_FAILED", lastError.Message);
            }
            finally
            {
                GlobalChunkSlots.Release();
            }
        }
    }

    private static bool IsChunkValid(FileStream stream, DepotManifest.ChunkData chunk)
    {
        if (chunk.UncompressedLength == 0) return true;
        if ((ulong)stream.Length < chunk.Offset + chunk.UncompressedLength) return false;
        var buffer = new byte[chunk.UncompressedLength];
        stream.Position = (long)chunk.Offset;
        var read = 0;
        while (read < buffer.Length)
        {
            var count = stream.Read(buffer, read, buffer.Length - read);
            if (count == 0) return false;
            read += count;
        }
        return DepotChunk.AdlerHash(buffer) == chunk.Checksum;
    }

    private static string ResolveContainedPath(string root, string relative)
    {
        var normalized = relative.Replace('\\', Path.DirectorySeparatorChar).Replace('/', Path.DirectorySeparatorChar);
        if (Path.IsPathRooted(normalized)) throw new ServiceException("UNSAFE_PATH", "The content manifest contains an absolute path.");
        var path = Path.GetFullPath(Path.Combine(root, normalized));
        var prefix = Path.GetFullPath(root) + Path.DirectorySeparatorChar;
        if (!path.StartsWith(prefix, StringComparison.Ordinal)) throw new ServiceException("UNSAFE_PATH", "The content manifest contains a path outside the staging directory.");
        return path;
    }

    private static void CopyDirectory(string source, string destination, CancellationToken cancellationToken)
    {
        ValidatePathIsNotLink(source);
        Directory.CreateDirectory(destination);
        var pending = new Stack<(string Source, string Destination)>();
        pending.Push((source, destination));
        while (pending.TryPop(out var current))
        {
            cancellationToken.ThrowIfCancellationRequested();
            foreach (var entry in Directory.EnumerateFileSystemEntries(current.Source))
            {
                cancellationToken.ThrowIfCancellationRequested();
                ValidatePathIsNotLink(entry);
                var target = Path.Combine(current.Destination, Path.GetFileName(entry));
                if (Directory.Exists(entry))
                {
                    Directory.CreateDirectory(target);
                    pending.Push((entry, target));
                }
                else
                {
                    File.Copy(entry, target, true);
                }
            }
        }
    }

    private static void ValidateNoLinks(string root, CancellationToken cancellationToken)
    {
        ValidatePathIsNotLink(root);
        var pending = new Stack<string>();
        pending.Push(root);
        while (pending.TryPop(out var directory))
        {
            cancellationToken.ThrowIfCancellationRequested();
            foreach (var entry in Directory.EnumerateFileSystemEntries(directory))
            {
                cancellationToken.ThrowIfCancellationRequested();
                ValidatePathIsNotLink(entry);
                if (Directory.Exists(entry)) pending.Push(entry);
            }
        }
    }

    private static void ValidatePathIsNotLink(string path)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
        {
            throw new ServiceException("UNSAFE_PATH", "The content directory contains a symbolic link.");
        }
    }

    private static void RemoveUnlistedFiles(string root, HashSet<string> allowed)
    {
        foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
        {
            if (!allowed.Contains(Path.GetFullPath(file))) File.Delete(file);
        }
        foreach (var directory in Directory.EnumerateDirectories(root, "*", SearchOption.AllDirectories).OrderByDescending(path => path.Length))
        {
            if (!Directory.EnumerateFileSystemEntries(directory).Any()) Directory.Delete(directory);
        }
    }

    private static void Install(string staging, string final, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var backup = final + ".previous";
        if (Directory.Exists(backup)) Directory.Delete(backup, true);
        if (Directory.Exists(final)) Directory.Move(final, backup);
        try
        {
            Directory.Move(staging, final);
            if (Directory.Exists(backup))
            {
                try { Directory.Delete(backup, true); } catch { }
            }
        }
        catch
        {
            if (!Directory.Exists(final) && Directory.Exists(backup)) Directory.Move(backup, final);
            throw;
        }
    }
}
