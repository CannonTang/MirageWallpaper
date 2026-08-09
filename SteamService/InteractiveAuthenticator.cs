//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

using SteamKit2.Authentication;

namespace MirageSteamService;

internal sealed class InteractiveAuthenticator : IAuthenticator
{
    private readonly ProtocolWriter writer;
    private readonly object gate = new();
    private TaskCompletionSource<string>? pendingCode;
    private volatile bool waitingForDeviceConfirmation;

    public bool IsWaitingForDeviceConfirmation => waitingForDeviceConfirmation;

    public InteractiveAuthenticator(ProtocolWriter writer)
    {
        this.writer = writer;
    }

    public Task<string> GetDeviceCodeAsync(bool previousCodeWasIncorrect)
    {
        waitingForDeviceConfirmation = false;
        return WaitForCode("mobileCode", previousCodeWasIncorrect ? "Previous mobile authenticator code was rejected." : null);
    }

    public Task<string> GetEmailCodeAsync(string email, bool previousCodeWasIncorrect)
    {
        waitingForDeviceConfirmation = false;
        return WaitForCode("emailCode", previousCodeWasIncorrect ? "Previous email authentication code was rejected." : email);
    }

    public Task<bool> AcceptDeviceConfirmationAsync()
    {
        waitingForDeviceConfirmation = true;
        writer.AuthState("waitingMobile");
        return Task.FromResult(true);
    }

    public bool Submit(string code)
    {
        TaskCompletionSource<string>? source;
        lock (gate)
        {
            source = pendingCode;
            pendingCode = null;
        }
        return source?.TrySetResult(code) == true;
    }

    public void Cancel()
    {
        waitingForDeviceConfirmation = false;
        TaskCompletionSource<string>? source;
        lock (gate)
        {
            source = pendingCode;
            pendingCode = null;
        }
        source?.TrySetCanceled();
    }

    private Task<string> WaitForCode(string state, string? message)
    {
        var source = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (gate) pendingCode = source;
        writer.AuthState(state, message: message);
        return source.Task;
    }
}
