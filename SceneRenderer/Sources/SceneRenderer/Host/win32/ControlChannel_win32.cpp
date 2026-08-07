// ControlChannel_win32.cpp
//
// Windows implementation of mirage::SceneControlChannel::readLoop().
// Replaces the POSIX poll()/read() path in ControlChannel.cpp with
// PeekNamedPipe + ReadFile, which work for both anonymous pipes
// (parent process stdin redirection) and console input handles.
//
// dispatchLine() is identical to the macOS implementation.

#include "ControlChannel.h"

#include <array>
#include <cstdio>
#include <iostream>
#include <string>

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

import sr.json;
import rstd.cppstd;
import sr.scene_wallpaper;

namespace mirage {

namespace {

bool ParseFillMode(const std::string& s, sr::FillMode& out) {
    if (s == "cover" || s == "aspectcrop" || s == "crop") {
        out = sr::FillMode::ASPECTCROP;
        return true;
    }
    if (s == "contain" || s == "fit" || s == "aspectfit") {
        out = sr::FillMode::ASPECTFIT;
        return true;
    }
    if (s == "stretch") {
        out = sr::FillMode::STRETCH;
        return true;
    }
    return false;
}

} // namespace

void SceneControlChannel::dispatchLine(const char* line) {
    if (line == nullptr) return;

    auto parsed = sr::ParseJson(line, { .allow_comments = true });
    if (parsed.is_err()) return;
    auto msg = parsed.unwrap();
    if (! msg.is_object()) return;
    auto command = msg.get("cmd");
    if (command.is_none()) return;
    auto command_text = (*command)->as_str();
    if (command_text.is_none()) return;

    const std::string cmd = rstd::cppstd::to_string(*command_text);

    if (cmd == "setProperty") {
        auto key_value = msg.get("key");
        if (key_value.is_none()) return;
        auto key_text = (*key_value)->as_str();
        if (key_text.is_none()) return;
        const std::string key = rstd::cppstd::to_string(*key_text);

        auto type = msg.get("type");
        auto value = msg.get("value");
        sr::Json prop = sr::Json::Null();
        if (type.is_some() && (*type)->is_string()) {
            auto object = rstd::json::Map::make();
            object.insert(::alloc::string::String::make(rstd::cppstd::as_str("type")),
                          (*type)->clone());
            object.insert(::alloc::string::String::make(rstd::cppstd::as_str("value")),
                          value.is_some() ? (*value)->clone() : sr::Json::Null());
            prop = sr::Json::Object(rstd::move(object));
        } else if (value.is_some()) {
            prop = (*value)->clone();
        } else {
            return;
        }
        m_wallpaper.setUserPropertyJson(key, std::move(prop));
    } else if (cmd == "pause") {
        m_wallpaper.pause();
    } else if (cmd == "resume" || cmd == "play") {
        m_wallpaper.play();
    } else if (cmd == "volume") {
        auto value = msg.get("value");
        if (value.is_some() && (*value)->is_number()) {
            auto number = (*value)->as_f64();
            if (number.is_some()) m_wallpaper.setVolume(static_cast<float>(*number));
        }
    } else if (cmd == "muted") {
        auto value = msg.get("value");
        if (value.is_some() && (*value)->is_boolean()) {
            m_wallpaper.setMuted(*(*value)->as_bool());
        }
    } else if (cmd == "fps") {
        auto value = msg.get("value");
        if (value.is_some() && (*value)->is_number()) {
            auto number = (*value)->as_u64();
            if (number.is_some()) m_wallpaper.setFps(static_cast<std::uint32_t>(*number));
        }
    } else if (cmd == "fillmode") {
        auto value = msg.get("value");
        if (value.is_some() && (*value)->is_string()) {
            sr::FillMode mode {};
            if (ParseFillMode(rstd::cppstd::to_string(*(*value)->as_str()), mode)) {
                m_wallpaper.setFillMode(mode);
            }
        }
    } else if (cmd == "speed") {
        auto value = msg.get("value");
        if (value.is_some() && (*value)->is_number()) {
            auto number = (*value)->as_f64();
            if (number.is_some()) m_wallpaper.setSpeed(static_cast<float>(*number));
        }
    } else if (cmd == "audioSpectrum") {
        auto data = msg.get("data");
        if (data.is_none() || !(*data)->is_array()) return;
        auto values = (*data)->as_array();
        if (values.is_none() || (*values)->len() != 128) return;
        std::array<float, 64> left {};
        std::array<float, 64> right {};
        std::size_t index = 0;
        for (const auto& value : **values) {
            auto number = value.as_f64();
            if (number.is_none()) return;
            if (index < 64)
                left[index] = static_cast<float>(*number);
            else
                right[index - 64] = static_cast<float>(*number);
            ++index;
        }
        m_wallpaper.setAudioSpectrum(std::move(left), std::move(right));
    } else if (cmd == "activate") {
        if (m_on_activate) m_on_activate();
    } else if (cmd == "quit") {
        m_running.store(false);
        if (m_on_quit) m_on_quit();
    }
}

void SceneControlChannel::readLoop() {
    HANDLE hStdin = GetStdHandle(STD_INPUT_HANDLE);
    std::string pending;
    char  buffer[4096];

    while (m_running.load()) {
        // Poll stdin for available data (100ms timeout, matching POSIX poll).
        DWORD available = 0;
        if (PeekNamedPipe(hStdin, nullptr, 0, nullptr, &available, nullptr)) {
            if (available == 0) {
                Sleep(100);
                continue;
            }
        } else {
            // PeekNamedPipe fails on non-pipe handles (e.g. direct console).
            // For a console handle, we can't poll with timeout — fall back to
            // a short sleep and hope data arrives.
            DWORD mode = 0;
            if (GetConsoleMode(hStdin, &mode)) {
                // Console mode: try a blocking ReadFile after a short wait.
                // Risk: blocks the thread until the user presses Enter.
                // In practice, --control-stdin is used with piped input, not
                // interactive console, so we just sleep here.
                Sleep(100);
                continue;
            }
            // Unknown handle type; give up polling.
            break;
        }

        DWORD count = 0;
        if (!ReadFile(hStdin, buffer, sizeof(buffer) - 1, &count, nullptr)) {
            // Error or parent closed the pipe.
            DWORD err = GetLastError();
            if (err == ERROR_BROKEN_PIPE || err == ERROR_NO_DATA) {
                // Parent closed the pipe — treat remaining data as final command,
                // then break (triggering m_on_quit).
                if (!pending.empty()) dispatchLine(pending.c_str());
                break;
            }
            // Other errors: retry after a pause.
            Sleep(100);
            continue;
        }

        if (count == 0) {
            // EOF
            if (!pending.empty()) dispatchLine(pending.c_str());
            break;
        }

        pending.append(buffer, static_cast<std::size_t>(count));

        // Split on newlines and dispatch complete commands.
        for (std::size_t newline;
             (newline = pending.find('\n')) != std::string::npos;) {
            std::string line = pending.substr(0, newline);
            pending.erase(0, newline + 1);
            if (!line.empty() && line.back() == '\r') line.pop_back();
            if (!line.empty()) dispatchLine(line.c_str());
            if (!m_running.load()) break;
        }

        // Bound unterminated/malformed stream to prevent unbounded growth.
        if (pending.size() > 1024 * 1024) pending.clear();
    }

    if (m_running.exchange(false)) {
        // Reached here via EOF / broken pipe (not explicit quit).
        if (m_on_quit) m_on_quit();
    }
}

} // namespace mirage
