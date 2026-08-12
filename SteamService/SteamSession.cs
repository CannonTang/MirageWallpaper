//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

using System.Collections.Concurrent;
using System.Net;
using System.Security.Cryptography;
using SteamKit2;
using SteamKit2.Authentication;
using SteamKit2.CDN;
using SteamKit2.Internal;
using SteamKit2.WebUI.Internal;

namespace MirageSteamService;

internal sealed class SteamSession : IAsyncDisposable
{
    public const uint AppId = 431960;
    private const uint WorkshopSubscriptionListType = 1;

    private readonly ProtocolWriter writer;
    private readonly SteamClient client;
    private readonly CallbackManager callbacks;
    private readonly SteamUser user;
    private readonly SteamApps apps;
    private readonly SteamContent content;
    private readonly PublishedFile publishedFiles;
    private readonly Community community;
    private readonly CancellationTokenSource lifetime = new();
    private readonly SemaphoreSlim authGate = new(1, 1);
    private readonly SemaphoreSlim appInfoGate = new(1, 1);
    private readonly SemaphoreSlim favoriteGate = new(1, 1);
    private readonly ConcurrentDictionary<(uint DepotId, string Host), SteamContent.CDNAuthToken> cdnTokens = new();
    private readonly Task callbackLoop;
    private TaskCompletionSource<bool>? connectedSource;
    private TaskCompletionSource<bool>? resetConnectionSource;
    private TaskCompletionSource<SteamUser.LoggedOnCallback>? loggedOnSource;
    private InteractiveAuthenticator? authenticator;
    private CancellationTokenSource? authCancellation;
    private SteamApps.PICSProductInfoCallback.PICSProductInfo? appInfo;
    private string refreshToken = "";
    private string accessToken = "";
    private bool shuttingDown;

    public bool IsLoggedIn { get; private set; }
    public string AccountName { get; private set; } = "";
    public string SteamId { get; private set; } = "";
    public SteamClient Client => client;
    public SteamApps Apps => apps;
    public SteamContent Content => content;
    public PublishedFile PublishedFiles => publishedFiles;

    public SteamSession(ProtocolWriter writer)
    {
        this.writer = writer;
        var configuration = SteamConfiguration.Create(builder => builder.WithHttpClientFactory(_ =>
        {
            var sockets = new SocketsHttpHandler
            {
                PooledConnectionLifetime = TimeSpan.FromMinutes(10),
                ConnectTimeout = TimeSpan.FromSeconds(20)
            };
            var httpClient = new HttpClient(new CountingHandler(sockets), true)
            {
                Timeout = Timeout.InfiniteTimeSpan
            };
            var version = typeof(SteamClient).Assembly.GetName().Version?.ToString(3) ?? "3.4.0";
            httpClient.DefaultRequestHeaders.UserAgent.ParseAdd($"SteamKit/{version}");
            return httpClient;
        }));
        client = new SteamClient(configuration);
        callbacks = new CallbackManager(client);
        user = client.GetHandler<SteamUser>()!;
        apps = client.GetHandler<SteamApps>()!;
        content = client.GetHandler<SteamContent>()!;
        var unifiedMessages = client.GetHandler<SteamUnifiedMessages>()!;
        publishedFiles = unifiedMessages.CreateService<PublishedFile>();
        community = unifiedMessages.CreateService<Community>();
        callbacks.Subscribe<SteamClient.ConnectedCallback>(OnConnected);
        callbacks.Subscribe<SteamClient.DisconnectedCallback>(OnDisconnected);
        callbacks.Subscribe<SteamUser.LoggedOnCallback>(OnLoggedOn);
        callbacks.Subscribe<SteamUser.LoggedOffCallback>(OnLoggedOff);
        callbackLoop = RunCallbacksAsync();
    }

    public async Task LoginWithRefreshTokenAsync(string username, string refreshToken, CancellationToken cancellationToken)
    {
        await authGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            writer.AuthState("connecting", username);
            await EnsureConnectedAsync(cancellationToken).ConfigureAwait(false);
            await LogOnAsync(username, refreshToken, cancellationToken).ConfigureAwait(false);
            this.refreshToken = refreshToken;
            accessToken = "";
            AccountName = username;
            writer.AuthState("loggedIn", username, steamId: SteamId);
        }
        finally
        {
            authGate.Release();
        }
    }

    public async Task LoginWithPasswordAsync(string username, string password, string? guardData, CancellationToken cancellationToken)
    {
        await authGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            CancelAuthentication();
            authCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, lifetime.Token);
            var loginAuthenticator = new InteractiveAuthenticator(writer);
            authenticator = loginAuthenticator;
            writer.AuthState("connecting", username);
            await EnsureConnectedAsync(authCancellation.Token).ConfigureAwait(false);
            writer.AuthState("authenticating", username);
            var session = await client.Authentication.BeginAuthSessionViaCredentialsAsync(new AuthSessionDetails
                {
                    Username = username,
                    Password = password,
                    IsPersistentSession = true,
                    GuardData = guardData,
                    Authenticator = loginAuthenticator,
                    DeviceFriendlyName = "Mirage for macOS"
                })
                .WaitAsync(authCancellation.Token)
                .ConfigureAwait(false);
            var result = await PollCredentialsResultAsync(session, loginAuthenticator, authCancellation.Token).ConfigureAwait(false);
            await LogOnAsync(result.AccountName, result.RefreshToken, authCancellation.Token).ConfigureAwait(false);
            refreshToken = result.RefreshToken;
            accessToken = result.AccessToken;
            AccountName = result.AccountName;
            writer.AuthState("loggedIn", result.AccountName, refreshToken: result.RefreshToken, guardData: result.NewGuardData ?? guardData, steamId: SteamId);
        }
        finally
        {
            authenticator = null;
            authCancellation?.Dispose();
            authCancellation = null;
            authGate.Release();
        }
    }

    public async Task LoginWithQrAsync(CancellationToken cancellationToken)
    {
        await authGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            CancelAuthentication();
            authCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, lifetime.Token);
            writer.AuthState("connecting");
            await EnsureConnectedAsync(authCancellation.Token).ConfigureAwait(false);
            var session = await client.Authentication.BeginAuthSessionViaQRAsync(new AuthSessionDetails
                {
                    IsPersistentSession = true,
                    DeviceFriendlyName = "Mirage for macOS"
                })
                .WaitAsync(authCancellation.Token)
                .ConfigureAwait(false);
            session.ChallengeURLChanged = () => writer.AuthState("qr", challengeUrl: session.ChallengeURL);
            writer.AuthState("qr", challengeUrl: session.ChallengeURL);
            var result = await session.PollingWaitForResultAsync(authCancellation.Token).ConfigureAwait(false);
            writer.AuthState("authenticating", result.AccountName);
            await LogOnAsync(result.AccountName, result.RefreshToken, authCancellation.Token).ConfigureAwait(false);
            refreshToken = result.RefreshToken;
            accessToken = result.AccessToken;
            AccountName = result.AccountName;
            writer.AuthState("loggedIn", result.AccountName, refreshToken: result.RefreshToken, guardData: result.NewGuardData, steamId: SteamId);
        }
        finally
        {
            authCancellation?.Dispose();
            authCancellation = null;
            authGate.Release();
        }
    }

    public bool SubmitChallenge(string code)
    {
        return authenticator?.Submit(code) == true;
    }

    private static async Task<AuthPollResult> PollCredentialsResultAsync(CredentialsAuthSession session, InteractiveAuthenticator loginAuthenticator, CancellationToken cancellationToken)
    {
        try
        {
            return await session.PollingWaitForResultAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (AsyncJobFailedException) when (loginAuthenticator.IsWaitingForDeviceConfirmation)
        {
            var failures = 1;
            var interval = session.PollingInterval < TimeSpan.FromSeconds(1) ? TimeSpan.FromSeconds(1) : session.PollingInterval;
            while (true)
            {
                await Task.Delay(interval, cancellationToken).ConfigureAwait(false);
                try
                {
                    var result = await session.PollAuthSessionStatusAsync().WaitAsync(cancellationToken).ConfigureAwait(false);
                    failures = 0;
                    if (result != null) return result;
                }
                catch (AsyncJobFailedException) when (failures < 5)
                {
                    failures += 1;
                }
                catch (AsyncJobFailedException)
                {
                    throw new ServiceException("AUTH_SERVICE_TEMPORARY", "Steam authentication service did not return the confirmed session.");
                }
            }
        }
    }

    public void CancelAuthentication()
    {
        authenticator?.Cancel();
        try { authCancellation?.Cancel(); } catch (ObjectDisposedException) { } catch (AggregateException) { }
    }

    public async Task ResetConnectionAsync()
    {
        var source = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        resetConnectionSource = source;
        connectedSource = null;
        loggedOnSource = null;
        client.Disconnect();
        try { await source.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false); } catch (TimeoutException) { }
        if (ReferenceEquals(resetConnectionSource, source)) resetConnectionSource = null;
    }

    public async Task<SteamApps.PICSProductInfoCallback.PICSProductInfo> GetAppInfoAsync(CancellationToken cancellationToken)
    {
        if (appInfo != null) return appInfo;
        await appInfoGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (appInfo != null) return appInfo;
            cancellationToken.ThrowIfCancellationRequested();
            var tokens = await apps.PICSGetAccessTokens([AppId], []).ToTask().WaitAsync(cancellationToken).ConfigureAwait(false);
            var request = new SteamApps.PICSRequest(AppId);
            if (tokens.AppTokens.TryGetValue(AppId, out var token)) request.AccessToken = token;
            cancellationToken.ThrowIfCancellationRequested();
            var response = await apps.PICSGetProductInfo([request], []).ToTask().WaitAsync(cancellationToken).ConfigureAwait(false);
            var results = response?.Results ?? throw new ServiceException("APP_INFO_UNAVAILABLE", "Wallpaper Engine app information is unavailable for this account.");
            foreach (var result in results)
            {
                if (result.Apps.TryGetValue(AppId, out var info))
                {
                    appInfo = info;
                    return info;
                }
            }
            throw new ServiceException("APP_INFO_UNAVAILABLE", "Wallpaper Engine app information is unavailable for this account.");
        }
        finally
        {
            appInfoGate.Release();
        }
    }

    public async Task<(Server Server, string? Token)> GetDownloadServerAsync(uint depotId, int offset, CancellationToken cancellationToken)
    {
        var servers = await content.GetServersForSteamPipe().WaitAsync(cancellationToken).ConfigureAwait(false);
        var eligible = servers
            .Where(server => !string.IsNullOrWhiteSpace(server.Host) && (server.AllowedAppIds.Length == 0 || server.AllowedAppIds.Contains(AppId)) && (server.Type == "CDN" || server.Type == "SteamCache"))
            .OrderBy(server => server.WeightedLoad)
            .ToArray();
        if (eligible.Length == 0) throw new ServiceException("NO_CONTENT_SERVER", "Steam returned no eligible content server.");
        var selected = eligible[Math.Abs(offset) % eligible.Length];
        var host = selected.Host!;
        var key = (depotId, host);
        if (!cdnTokens.TryGetValue(key, out var auth) || auth.Expiration <= DateTime.UtcNow.AddMinutes(1))
        {
            var result = await content.GetCDNAuthToken(AppId, depotId, host).WaitAsync(cancellationToken).ConfigureAwait(false);
            if (result.Result == EResult.OK)
            {
                auth = result;
                cdnTokens[key] = result;
            }
            else
            {
                return (selected, null);
            }
        }
        return (selected, auth.Token);
    }

    public async Task<SubscriptionPage> GetSubscriptionsAsync(int startIndex, CancellationToken cancellationToken)
    {
        const int pageSize = 50;
        if (!ulong.TryParse(SteamId, out var steamId))
        {
            throw new ServiceException("NOT_AUTHENTICATED", "The Steam session has no valid Steam ID.");
        }
        var normalizedStart = Math.Max(0, startIndex);
        var request = new CPublishedFile_GetUserFiles_Request
        {
            steamid = steamId,
            appid = AppId,
            page = checked((uint)(normalizedStart / pageSize + 1)),
            numperpage = pageSize,
            type = "mysubscriptions"
        };
        var response = await publishedFiles.GetUserFiles(request)
            .ToTask()
            .WaitAsync(cancellationToken)
            .ConfigureAwait(false);
        EnsureSuccess(response.Result, "SUBSCRIPTIONS_UNAVAILABLE");
        var files = response.Body.publishedfiledetails
            .Where(file => file.consumer_appid == AppId)
            .Select(file => new SubscribedFile(
                file.publishedfileid,
                file.time_subscribed,
                file.time_updated,
                file.hcontent_file,
                file.file_size,
                file.consumer_appid))
            .ToArray();
        return new SubscriptionPage(
            checked((int)response.Body.total),
            normalizedStart,
            files);
    }

    public async Task<FavoritePage> GetFavoritesAsync(int startIndex, CancellationToken cancellationToken)
    {
        const int pageSize = 50;
        if (!ulong.TryParse(SteamId, out var steamId))
        {
            throw new ServiceException("NOT_AUTHENTICATED", "The Steam session has no valid Steam ID.");
        }
        var normalizedStart = Math.Max(0, startIndex);
        var request = new CPublishedFile_GetUserFiles_Request
        {
            steamid = steamId,
            appid = AppId,
            page = checked((uint)(normalizedStart / pageSize + 1)),
            numperpage = pageSize,
            type = "myfavorites",
            ids_only = true
        };
        var response = await publishedFiles.GetUserFiles(request)
            .ToTask()
            .WaitAsync(cancellationToken)
            .ConfigureAwait(false);
        EnsureSuccess(response.Result, "FAVORITES_UNAVAILABLE");
        var ids = response.Body.publishedfiledetails
            .Where(file => file.consumer_appid == 0 || file.consumer_appid == AppId)
            .Select(file => file.publishedfileid)
            .Where(id => id != 0)
            .ToArray();
        return new FavoritePage(
            checked((int)response.Body.total),
            normalizedStart,
            normalizedStart + pageSize,
            ids);
    }

    public async Task SetFavoriteAsync(ulong workshopId, bool favorite, CancellationToken cancellationToken)
    {
        await favoriteGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            for (var attempt = 0; attempt < 2; attempt++)
            {
                var token = await GetCommunityAccessTokenAsync(attempt > 0, cancellationToken).ConfigureAwait(false);
                var sessionId = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(12));
                var cookies = new CookieContainer();
                cookies.Add(new Cookie("sessionid", sessionId, "/", ".steamcommunity.com"));
                cookies.Add(new Cookie("steamLoginSecure", $"{SteamId}||{token}", "/", ".steamcommunity.com"));
                using var handler = new HttpClientHandler
                {
                    CookieContainer = cookies,
                    AllowAutoRedirect = true
                };
                using var http = new HttpClient(handler)
                {
                    Timeout = TimeSpan.FromSeconds(30)
                };
                http.DefaultRequestHeaders.UserAgent.ParseAdd("Mirage Wallpaper/1.0");
                var endpoint = favorite ? "favorite" : "unfavorite";
                using var request = new HttpRequestMessage(
                    HttpMethod.Post,
                    $"https://steamcommunity.com/sharedfiles/{endpoint}");
                request.Headers.Referrer = new Uri(
                    $"https://steamcommunity.com/sharedfiles/filedetails/?id={workshopId}");
                request.Content = new FormUrlEncodedContent(new Dictionary<string, string>
                {
                    ["id"] = workshopId.ToString(),
                    ["appid"] = AppId.ToString(),
                    ["sessionid"] = sessionId
                });
                using var response = await http.SendAsync(request, cancellationToken).ConfigureAwait(false);
                if (response.IsSuccessStatusCode &&
                    await WaitForFavoriteStateAsync(workshopId, favorite, cancellationToken).ConfigureAwait(false))
                {
                    return;
                }
                accessToken = "";
            }
            throw new ServiceException(
                favorite ? "FAVORITE_ADD_FAILED" : "FAVORITE_REMOVE_FAILED",
                "Steam did not confirm the requested favorite state.");
        }
        finally
        {
            favoriteGate.Release();
        }
    }

    private async Task<string> GetCommunityAccessTokenAsync(bool forceRefresh, CancellationToken cancellationToken)
    {
        if (!forceRefresh && !string.IsNullOrWhiteSpace(accessToken)) return accessToken;
        if (!ulong.TryParse(SteamId, out var steamId) || string.IsNullOrWhiteSpace(refreshToken))
        {
            throw new ServiceException("NOT_AUTHENTICATED", "The Steam session has no reusable authentication token.");
        }
        var result = await client.Authentication
            .GenerateAccessTokenForAppAsync(new SteamID(steamId), refreshToken)
            .WaitAsync(cancellationToken)
            .ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(result.AccessToken))
        {
            throw new ServiceException("FAVORITE_SESSION_FAILED", "Steam did not issue a community access token.");
        }
        accessToken = result.AccessToken;
        return accessToken;
    }

    private async Task<bool> WaitForFavoriteStateAsync(ulong workshopId, bool favorite, CancellationToken cancellationToken)
    {
        for (var attempt = 0; attempt < 10; attempt++)
        {
            if (await IsFavoriteAsync(workshopId, cancellationToken).ConfigureAwait(false) == favorite) return true;
            await Task.Delay(500, cancellationToken).ConfigureAwait(false);
        }
        return await IsFavoriteAsync(workshopId, cancellationToken).ConfigureAwait(false) == favorite;
    }

    private async Task<bool> IsFavoriteAsync(ulong workshopId, CancellationToken cancellationToken)
    {
        var startIndex = 0;
        while (true)
        {
            var page = await GetFavoritesAsync(startIndex, cancellationToken).ConfigureAwait(false);
            if (page.PublishedFileIds.Contains(workshopId)) return true;
            if (page.NextStartIndex >= page.TotalResults) return false;
            startIndex = page.NextStartIndex;
        }
    }

    public async Task<IReadOnlyDictionary<ulong, bool>> GetSubscriptionStatesAsync(IEnumerable<ulong> workshopIds, CancellationToken cancellationToken)
    {
        var states = new Dictionary<ulong, bool>();
        foreach (var chunk in workshopIds.Distinct().Chunk(100))
        {
            var request = new CPublishedFile_AreFilesInSubscriptionList_Request { appid = AppId, listtype = WorkshopSubscriptionListType };
            request.publishedfileids.AddRange(chunk);
            var response = await publishedFiles.AreFilesInSubscriptionList(request)
                .ToTask()
                .WaitAsync(cancellationToken)
                .ConfigureAwait(false);
            EnsureSuccess(response.Result, "SUBSCRIPTION_STATUS_UNAVAILABLE");
            foreach (var item in response.Body.files)
            {
                states[item.publishedfileid] = item.inlist;
            }
        }
        return states;
    }

    public async Task SubscribeAsync(ulong workshopId, CancellationToken cancellationToken)
    {
        var request = new CPublishedFile_Subscribe_Request
        {
            publishedfileid = workshopId,
            list_type = WorkshopSubscriptionListType,
            appid = checked((int)AppId),
            notify_client = true,
            include_dependencies = true
        };
        var response = await publishedFiles.Subscribe(request)
            .ToTask()
            .WaitAsync(cancellationToken)
            .ConfigureAwait(false);
        EnsureSuccess(response.Result, "SUBSCRIBE_FAILED");
    }

    public async Task UnsubscribeAsync(ulong workshopId, CancellationToken cancellationToken)
    {
        var request = new CPublishedFile_Unsubscribe_Request
        {
            publishedfileid = workshopId,
            list_type = WorkshopSubscriptionListType,
            appid = checked((int)AppId),
            notify_client = true
        };
        var response = await publishedFiles.Unsubscribe(request)
            .ToTask()
            .WaitAsync(cancellationToken)
            .ConfigureAwait(false);
        EnsureSuccess(response.Result, "UNSUBSCRIBE_FAILED");
    }

    public async Task<CommentPage> GetCommentsAsync(ulong workshopId, ulong creatorSteamId, int startIndex, int count, CancellationToken cancellationToken)
    {
        var request = new CCommunity_GetCommentThread_Request
        {
            steamid = creatorSteamId,
            comment_thread_type = (int)ECommentThreadType.k_ECommentThreadTypePublishedFile_Public,
            gidfeature = workshopId,
            start = Math.Max(0, startIndex),
            count = Math.Clamp(count, 1, 50),
            upvoters = 3,
            oldest_first = false
        };
        var response = await community.GetCommentThread(request)
            .ToTask()
            .WaitAsync(cancellationToken)
            .ConfigureAwait(false);
        EnsureSuccess(response.Result, "COMMENTS_UNAVAILABLE");
        var receivedComments = response.Body.comments;
        var comments = receivedComments
            .Where(comment => !comment.deleted)
            .Select(comment => new SteamComment(
                comment.gidcomment,
                comment.steamid,
                comment.timestamp,
                comment.text,
                comment.upvotes,
                comment.hidden || comment.hidden_by_user))
            .ToArray();
        return new CommentPage(
            response.Body.total_count,
            response.Body.can_post,
            startIndex + receivedComments.Count,
            comments);
    }

    public async Task<ulong> PostCommentAsync(ulong workshopId, ulong creatorSteamId, string text, CancellationToken cancellationToken)
    {
        var request = new CCommunity_PostCommentToThread_Request
        {
            steamid = creatorSteamId,
            comment_thread_type = (int)ECommentThreadType.k_ECommentThreadTypePublishedFile_Public,
            gidfeature = workshopId,
            text = text,
            suppress_notifications = false
        };
        var response = await community.PostCommentToThread(request)
            .ToTask()
            .WaitAsync(cancellationToken)
            .ConfigureAwait(false);
        EnsureSuccess(response.Result, "COMMENT_POST_FAILED");
        return response.Body.gidcomment;
    }

    public void Logout()
    {
        CancelAuthentication();
        IsLoggedIn = false;
        AccountName = "";
        SteamId = "";
        refreshToken = "";
        accessToken = "";
        appInfo = null;
        cdnTokens.Clear();
        if (client.IsConnected) user.LogOff();
        writer.AuthState("loggedOut");
    }

    private async Task EnsureConnectedAsync(CancellationToken cancellationToken)
    {
        if (client.IsConnected) return;
        Exception? lastError = null;
        for (var attempt = 0; attempt < 4; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            connectedSource = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            try
            {
                client.Connect();
                await connectedSource.Task.WaitAsync(TimeSpan.FromSeconds(12), cancellationToken).ConfigureAwait(false);
                return;
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception error)
            {
                lastError = error;
                connectedSource = null;
                try { client.Disconnect(); } catch { }
                if (attempt < 3)
                {
                    await Task.Delay(TimeSpan.FromMilliseconds(500 * (attempt + 1)), cancellationToken).ConfigureAwait(false);
                }
            }
        }
        throw lastError ?? new ServiceException("CONNECTION_LOST", "Steam connection closed.");
    }

    private async Task LogOnAsync(string username, string refreshToken, CancellationToken cancellationToken)
    {
        loggedOnSource = new TaskCompletionSource<SteamUser.LoggedOnCallback>(TaskCreationOptions.RunContinuationsAsynchronously);
        user.LogOn(new SteamUser.LogOnDetails
        {
            Username = username,
            AccessToken = refreshToken,
            ShouldRememberPassword = true,
            LoginID = 0x4D495247
        });
        var result = await loggedOnSource.Task.WaitAsync(TimeSpan.FromSeconds(30), cancellationToken).ConfigureAwait(false);
        if (result.Result != EResult.OK) throw new ServiceException("AUTH_FAILED", result.Result.ToString());
        SteamId = result.ClientSteamID?.ConvertToUInt64().ToString() ?? "";
        IsLoggedIn = true;
    }

    private static void EnsureSuccess(EResult result, string code)
    {
        if (result != EResult.OK)
        {
            throw new ServiceException(code, result.ToString());
        }
    }

    private async Task RunCallbacksAsync()
    {
        try
        {
            while (!lifetime.IsCancellationRequested)
            {
                await callbacks.RunWaitCallbackAsync(lifetime.Token).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception error)
        {
            Console.Error.WriteLine(error);
        }
    }

    private void OnConnected(SteamClient.ConnectedCallback callback)
    {
        connectedSource?.TrySetResult(true);
    }

    private void OnDisconnected(SteamClient.DisconnectedCallback callback)
    {
        if (callback.UserInitiated)
        {
            resetConnectionSource?.TrySetResult(true);
            return;
        }
        connectedSource?.TrySetException(new ServiceException("CONNECTION_LOST", "Steam connection closed."));
        loggedOnSource?.TrySetException(new ServiceException("CONNECTION_LOST", "Steam connection closed."));
        if (IsLoggedIn && !shuttingDown)
        {
            IsLoggedIn = false;
            AccountName = "";
            SteamId = "";
            refreshToken = "";
            accessToken = "";
            writer.AuthState("loggedOut", message: "Steam connection closed.", errorCode: "CONNECTION_LOST");
        }
    }

    private void OnLoggedOn(SteamUser.LoggedOnCallback callback)
    {
        loggedOnSource?.TrySetResult(callback);
    }

    private void OnLoggedOff(SteamUser.LoggedOffCallback callback)
    {
        if (shuttingDown || !IsLoggedIn) return;
        IsLoggedIn = false;
        AccountName = "";
        SteamId = "";
        refreshToken = "";
        accessToken = "";
        writer.AuthState("loggedOut", message: callback.Result.ToString());
    }

    public async ValueTask DisposeAsync()
    {
        shuttingDown = true;
        CancelAuthentication();
        if (client.IsConnected)
        {
            if (IsLoggedIn) user.LogOff();
            client.Disconnect();
        }
        lifetime.Cancel();
        try { await callbackLoop.ConfigureAwait(false); } catch { }
        lifetime.Dispose();
        authGate.Dispose();
        appInfoGate.Dispose();
        favoriteGate.Dispose();
    }
}

internal sealed record SubscriptionPage(
    int TotalResults,
    int StartIndex,
    IReadOnlyList<SubscribedFile> Files);

internal sealed record FavoritePage(
    int TotalResults,
    int StartIndex,
    int NextStartIndex,
    IReadOnlyList<ulong> PublishedFileIds);

internal sealed record SubscribedFile(
    ulong PublishedFileId,
    uint SubscribedAt,
    uint UpdatedAt,
    ulong ContentHash,
    ulong FileSize,
    uint AppId);

internal sealed record SteamComment(
    ulong CommentId,
    ulong AuthorSteamId,
    uint Timestamp,
    string Text,
    int Upvotes,
    bool Hidden);

internal sealed record CommentPage(
    int TotalCount,
    bool CanPost,
    int NextStartIndex,
    IReadOnlyList<SteamComment> Comments);
