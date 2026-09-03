#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <windowsx.h>
#include <mmsystem.h>
#include <commctrl.h>
#include <string>
#include <vector>
#include <atomic>
#include <cmath>
#include <iostream>

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "winmm.lib")
#pragma comment(lib, "ws2_32.lib")

// Window dimensions (Retina 3.5" proportional scale)
const int WIN_WIDTH = 360;
const int WIN_HEIGHT = 640;

// UI State
struct PlayerState {
    std::wstring title = L"Sendspin Player";
    std::wstring artist = L"Dominus Soul";
    std::wstring album = L"The Singles";
    std::wstring serverStatus = L"Port 8928 (mDNS Active)";
    std::wstring serverHost = L"127.0.0.1";
    int serverPort = 8927;
    bool isConnected = false;
    bool isPlaying = false;
    uint32_t durationMs = 174000;
    uint32_t progressMs = 45000;
    float volume = 0.85f;
    int32_t delayMs = 0;
    bool isScrubbing = false;
};

static PlayerState g_state;
static HWND g_hWnd = NULL;
static HWAVEOUT g_hWaveOut = NULL;
static std::atomic<bool> g_audioRunning(false);
static HANDLE g_hAudioThread = NULL;

// WaveOut Audio Engine (Plays test tone / stream lock-free)
DWORD WINAPI AudioPlaybackThread(LPVOID lpParam) {
    WAVEFORMATEX wfx = {};
    wfx.wFormatTag = WAVE_FORMAT_PCM;
    wfx.nChannels = 2;
    wfx.nSamplesPerSec = 44100;
    wfx.wBitsPerSample = 16;
    wfx.nBlockAlign = (wfx.nChannels * wfx.wBitsPerSample) / 8;
    wfx.nAvgBytesPerSec = wfx.nSamplesPerSec * wfx.nBlockAlign;

    if (waveOutOpen(&g_hWaveOut, WAVE_MAPPER, &wfx, 0, 0, CALLBACK_NULL) != MMSYSERR_NOERROR) {
        return 0;
    }

    const int BUFFER_SAMPLES = 2048;
    const int BUFFER_BYTES = BUFFER_SAMPLES * wfx.nBlockAlign;
    const int NUM_BUFFERS = 4;
    
    std::vector<std::vector<int16_t>> buffers(NUM_BUFFERS, std::vector<int16_t>(BUFFER_SAMPLES * 2));
    std::vector<WAVEHDR> headers(NUM_BUFFERS);

    for (int i = 0; i < NUM_BUFFERS; ++i) {
        ZeroMemory(&headers[i], sizeof(WAVEHDR));
        headers[i].lpData = (LPSTR)buffers[i].data();
        headers[i].dwBufferLength = BUFFER_BYTES;
        waveOutPrepareHeader(g_hWaveOut, &headers[i], sizeof(WAVEHDR));
        headers[i].dwFlags |= WHDR_DONE;
    }

    double phase = 0.0;
    int bufIdx = 0;

    while (g_audioRunning) {
        WAVEHDR* hdr = &headers[bufIdx];
        while (!(hdr->dwFlags & WHDR_DONE) && g_audioRunning) {
            Sleep(2);
        }
        if (!g_audioRunning) break;

        int16_t* pcm = buffers[bufIdx].data();
        float vol = g_state.isPlaying ? g_state.volume : 0.0f;

        for (int i = 0; i < BUFFER_SAMPLES; ++i) {
            int16_t sample = 0;
            if (g_state.isPlaying) {
                // Generate smooth Hi-Fi test tone / music synthesizer loop
                sample = static_cast<int16_t>(std::sin(phase) * 12000.0 * vol);
                phase += 2.0 * 3.1415926535 * 440.0 / 44100.0;
                if (phase > 2.0 * 3.1415926535) phase -= 2.0 * 3.1415926535;
            }
            pcm[i * 2] = sample;
            pcm[i * 2 + 1] = sample;
        }

        waveOutWrite(g_hWaveOut, hdr, sizeof(WAVEHDR));
        bufIdx = (bufIdx + 1) % NUM_BUFFERS;
    }

    waveOutReset(g_hWaveOut);
    for (int i = 0; i < NUM_BUFFERS; ++i) {
        waveOutUnprepareHeader(g_hWaveOut, &headers[i], sizeof(WAVEHDR));
    }
    waveOutClose(g_hWaveOut);
    g_hWaveOut = NULL;
    return 0;
}

std::wstring FormatTime(uint32_t ms) {
    uint32_t totalSec = ms / 1000;
    uint32_t min = totalSec / 60;
    uint32_t sec = totalSec % 60;
    wchar_t buf[32];
    swprintf(buf, 32, L"%u:%02u", min, sec);
    return buf;
}

void DrawRoundRect(HDC hdc, int x, int y, int w, int h, int r, COLORREF fill, COLORREF border) {
    HBRUSH hBrush = CreateSolidBrush(fill);
    HPEN hPen = CreatePen(PS_SOLID, 1, border);
    HGDIOBJ oldBrush = SelectObject(hdc, hBrush);
    HGDIOBJ oldPen = SelectObject(hdc, hPen);
    RoundRect(hdc, x, y, x + w, y + h, r, r);
    SelectObject(hdc, oldBrush);
    SelectObject(hdc, oldPen);
    DeleteObject(hBrush);
    DeleteObject(hPen);
}

void RenderUI(HDC hdc, int width, int height) {
    // 1. Background
    HBRUSH bgBrush = CreateSolidBrush(RGB(18, 20, 26));
    RECT bgRect = {0, 0, width, height};
    FillRect(hdc, &bgRect, bgBrush);
    DeleteObject(bgBrush);

    // 2. Top Header Bar
    DrawRoundRect(hdc, 0, 0, width, 46, 0, RGB(26, 30, 38), RGB(48, 54, 66));
    
    // Status Dot
    COLORREF dotColor = g_state.isConnected ? RGB(50, 200, 80) : RGB(80, 180, 240);
    HBRUSH dotBrush = CreateSolidBrush(dotColor);
    HGDIOBJ oldBrush = SelectObject(hdc, dotBrush);
    SelectObject(hdc, GetStockObject(NULL_PEN));
    Ellipse(hdc, 16, 18, 28, 30);
    SelectObject(hdc, oldBrush);
    DeleteObject(dotBrush);

    // Status Label
    SetBkMode(hdc, TRANSPARENT);
    SetTextColor(hdc, RGB(230, 235, 245));
    HFONT hFontSmall = CreateFont(15, 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    HGDIOBJ oldFont = SelectObject(hdc, hFontSmall);
    RECT statusRect = {34, 13, width - 90, 36};
    DrawText(hdc, g_state.serverStatus.c_str(), -1, &statusRect, DT_LEFT | DT_VCENTER | DT_SINGLELINE);

    // Server Button
    DrawRoundRect(hdc, width - 82, 10, 70, 26, 6, RGB(35, 40, 52), RGB(220, 185, 80));
    SetTextColor(hdc, RGB(240, 210, 110));
    RECT btnRect = {width - 82, 10, width - 12, 36};
    DrawText(hdc, L"⚙ Server", -1, &btnRect, DT_CENTER | DT_VCENTER | DT_SINGLELINE);

    // 3. Album Artwork Card (Vinyl Art)
    int coverSize = 200;
    int coverX = (width - coverSize) / 2;
    int coverY = 66;
    DrawRoundRect(hdc, coverX, coverY, coverSize, coverSize, 16, RGB(30, 34, 44), RGB(70, 75, 90));

    // Vinyl Record Concentric Rings
    HPEN ringPen = CreatePen(PS_SOLID, 1, RGB(45, 50, 65));
    SelectObject(hdc, ringPen);
    SelectObject(hdc, GetStockObject(NULL_BRUSH));
    Ellipse(hdc, coverX + 20, coverY + 20, coverX + coverSize - 20, coverY + coverSize - 20);
    Ellipse(hdc, coverX + 45, coverY + 45, coverX + coverSize - 45, coverY + coverSize - 45);
    Ellipse(hdc, coverX + 70, coverY + 70, coverX + coverSize - 70, coverY + coverSize - 70);
    DeleteObject(ringPen);

    // Gold Center Label
    HBRUSH centerBrush = CreateSolidBrush(RGB(220, 185, 80));
    SelectObject(hdc, centerBrush);
    Ellipse(hdc, coverX + 80, coverY + 80, coverX + coverSize - 80, coverY + coverSize - 80);
    DeleteObject(centerBrush);

    // 4. Track Title & Artist / Album
    HFONT hFontTitle = CreateFont(20, 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    SelectObject(hdc, hFontTitle);
    SetTextColor(hdc, RGB(255, 255, 255));
    RECT titleRect = {16, 280, width - 16, 306};
    DrawText(hdc, g_state.title.c_str(), -1, &titleRect, DT_CENTER | DT_SINGLELINE | DT_NOPREFIX);

    HFONT hFontArtist = CreateFont(15, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    SelectObject(hdc, hFontArtist);
    SetTextColor(hdc, RGB(220, 190, 120));
    std::wstring artistAlbum = g_state.artist + L" — " + g_state.album;
    RECT artistRect = {16, 308, width - 16, 330};
    DrawText(hdc, artistAlbum.c_str(), -1, &artistRect, DT_CENTER | DT_SINGLELINE | DT_NOPREFIX);

    // 5. Progress Slider & Timers
    int progY = 346;
    int progW = width - 36;
    int progX = 18;
    DrawRoundRect(hdc, progX, progY, progW, 6, 3, RGB(40, 45, 58), RGB(40, 45, 58));
    
    float progFrac = g_state.durationMs > 0 ? (float)g_state.progressMs / g_state.durationMs : 0.0f;
    int fillW = static_cast<int>(progFrac * progW);
    DrawRoundRect(hdc, progX, progY, fillW, 6, 3, RGB(220, 185, 80), RGB(220, 185, 80));
    
    // Scrubber Knob
    HBRUSH knobBrush = CreateSolidBrush(RGB(255, 255, 255));
    SelectObject(hdc, knobBrush);
    Ellipse(hdc, progX + fillW - 6, progY - 4, progX + fillW + 8, progY + 10);
    DeleteObject(knobBrush);

    // Timers
    SelectObject(hdc, hFontSmall);
    SetTextColor(hdc, RGB(140, 150, 165));
    RECT curTimeRect = {18, progY + 10, 100, progY + 28};
    DrawText(hdc, FormatTime(g_state.progressMs).c_str(), -1, &curTimeRect, DT_LEFT);

    RECT totTimeRect = {width - 100, progY + 10, width - 18, progY + 28};
    DrawText(hdc, FormatTime(g_state.durationMs).c_str(), -1, &totTimeRect, DT_RIGHT);

    // 6. Playback Transport Bar
    int ctrlY = 394;
    // Prev Button
    DrawRoundRect(hdc, (width / 2) - 86, ctrlY + 4, 46, 42, 8, RGB(30, 34, 44), RGB(50, 56, 70));
    SetTextColor(hdc, RGB(255, 255, 255));
    RECT prevRect = {(width / 2) - 86, ctrlY + 4, (width / 2) - 40, ctrlY + 46};
    DrawText(hdc, L"|◀◀", -1, &prevRect, DT_CENTER | DT_VCENTER | DT_SINGLELINE);

    // Play/Pause Big Gold Button
    DrawRoundRect(hdc, (width - 60) / 2, ctrlY, 60, 50, 25, RGB(220, 185, 80), RGB(240, 205, 100));
    SetTextColor(hdc, RGB(18, 20, 26));
    HFONT hFontPlay = CreateFont(22, 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    SelectObject(hdc, hFontPlay);
    RECT playRect = {(width - 60) / 2, ctrlY, (width + 60) / 2, ctrlY + 50};
    DrawText(hdc, g_state.isPlaying ? L"❚❚" : L"▶", -1, &playRect, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    DeleteObject(hFontPlay);

    // Next Button
    SelectObject(hdc, hFontSmall);
    DrawRoundRect(hdc, (width / 2) + 40, ctrlY + 4, 46, 42, 8, RGB(30, 34, 44), RGB(50, 56, 70));
    SetTextColor(hdc, RGB(255, 255, 255));
    RECT nextRect = {(width / 2) + 40, ctrlY + 4, (width / 2) + 86, ctrlY + 46};
    DrawText(hdc, L"▶▶|", -1, &nextRect, DT_CENTER | DT_VCENTER | DT_SINGLELINE);

    // 7. Volume Slider
    int volY = 468;
    SetTextColor(hdc, RGB(150, 160, 175));
    RECT volMinRect = {18, volY - 2, 36, volY + 16};
    DrawText(hdc, L"🔈", -1, &volMinRect, DT_LEFT);

    int volBarX = 46;
    int volBarW = width - 92;
    DrawRoundRect(hdc, volBarX, volY + 4, volBarW, 6, 3, RGB(40, 45, 58), RGB(40, 45, 58));
    int volFillW = static_cast<int>(g_state.volume * volBarW);
    DrawRoundRect(hdc, volBarX, volY + 4, volFillW, 6, 3, RGB(90, 170, 250), RGB(90, 170, 250));

    RECT volMaxRect = {width - 38, volY - 2, width - 16, volY + 16};
    DrawText(hdc, L"🔊", -1, &volMaxRect, DT_RIGHT);

    // 8. Sync Delay Panel
    int delayY = 512;
    DrawRoundRect(hdc, 12, delayY, width - 24, 46, 8, RGB(25, 29, 37), RGB(48, 54, 66));
    
    wchar_t delayBuf[32];
    swprintf(delayBuf, 32, L"Sync: %+d ms", g_state.delayMs);
    SetTextColor(hdc, RGB(220, 225, 235));
    RECT delayRect = {20, delayY + 12, 120, delayY + 34};
    DrawText(hdc, delayBuf, -1, &delayRect, DT_LEFT | DT_VCENTER | DT_SINGLELINE);

    // Delay Buttons [-10] [-1] [+1] [+10] [0]
    const wchar_t* btnLabels[] = {L"-10", L"-1", L"+1", L"+10", L"0"};
    int dBtnW = 34;
    int dBtnH = 26;
    int dStartX = width - 210;

    for (int i = 0; i < 5; ++i) {
        int bx = dStartX + i * (dBtnW + 4);
        int by = delayY + 10;
        COLORREF bgC = (i == 4) ? RGB(220, 185, 80) : RGB(40, 46, 58);
        COLORREF fgC = (i == 4) ? RGB(18, 20, 26) : RGB(230, 235, 245);
        DrawRoundRect(hdc, bx, by, dBtnW, dBtnH, 4, bgC, RGB(60, 68, 85));
        SetTextColor(hdc, fgC);
        RECT dbRect = {bx, by, bx + dBtnW, by + dBtnH};
        DrawText(hdc, btnLabels[i], -1, &dbRect, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    }

    // 9. Bottom Status Hint
    SetTextColor(hdc, RGB(100, 110, 125));
    RECT hintRect = {0, height - 38, width, height - 12};
    DrawText(hdc, L"Sendspin Universal Client · Windows Test Edition", -1, &hintRect, DT_CENTER | DT_SINGLELINE);

    SelectObject(hdc, oldFont);
    DeleteObject(hFontSmall);
    DeleteObject(hFontTitle);
    DeleteObject(hFontArtist);
}

LRESULT CALLBACK WndProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
        case WM_CREATE:
            SetTimer(hWnd, 1, 200, NULL); // 5Hz UI progress timer
            return 0;

        case WM_TIMER:
            if (g_state.isPlaying && !g_state.isScrubbing) {
                g_state.progressMs += 200;
                if (g_state.progressMs > g_state.durationMs) {
                    g_state.progressMs = 0;
                }
                InvalidateRect(hWnd, NULL, FALSE);
            }
            return 0;

        case WM_LBUTTONDOWN: {
            int x = GET_X_LPARAM(lParam);
            int y = GET_Y_LPARAM(lParam);

            // Play/Pause button
            if (x >= (WIN_WIDTH - 60) / 2 && x <= (WIN_WIDTH + 60) / 2 && y >= 394 && y <= 444) {
                g_state.isPlaying = !g_state.isPlaying;
                InvalidateRect(hWnd, NULL, FALSE);
            }
            // Prev Button
            else if (x >= (WIN_WIDTH / 2) - 86 && x <= (WIN_WIDTH / 2) - 40 && y >= 398 && y <= 440) {
                g_state.progressMs = 0;
                InvalidateRect(hWnd, NULL, FALSE);
            }
            // Next Button
            else if (x >= (WIN_WIDTH / 2) + 40 && x <= (WIN_WIDTH / 2) + 86 && y >= 398 && y <= 440) {
                g_state.progressMs = 0;
                InvalidateRect(hWnd, NULL, FALSE);
            }
            // Server Button
            else if (x >= WIN_WIDTH - 82 && x <= WIN_WIDTH - 12 && y >= 10 && y <= 36) {
                int res = MessageBox(hWnd, L"Connect to Sendspin / Music Assistant server on 127.0.0.1:8927?\n\nPress YES to simulate connection, NO to toggle offline.", L"Sendspin Server Connection", MB_YESNOCANCEL | MB_ICONINFORMATION);
                if (res == IDYES) {
                    g_state.isConnected = true;
                    g_state.serverStatus = L"Sync: Music Assistant";
                } else if (res == IDNO) {
                    g_state.isConnected = false;
                    g_state.serverStatus = L"Port 8928 (mDNS Active)";
                }
                InvalidateRect(hWnd, NULL, FALSE);
            }
            // Progress Bar Scrubbing
            else if (y >= 338 && y <= 360 && x >= 18 && x <= WIN_WIDTH - 18) {
                g_state.isScrubbing = true;
                float frac = (float)(x - 18) / (float)(WIN_WIDTH - 36);
                if (frac < 0.0f) frac = 0.0f;
                if (frac > 1.0f) frac = 1.0f;
                g_state.progressMs = static_cast<uint32_t>(frac * g_state.durationMs);
                InvalidateRect(hWnd, NULL, FALSE);
            }
            // Volume Slider
            else if (y >= 460 && y <= 485 && x >= 46 && x <= WIN_WIDTH - 46) {
                float frac = (float)(x - 46) / (float)(WIN_WIDTH - 92);
                if (frac < 0.0f) frac = 0.0f;
                if (frac > 1.0f) frac = 1.0f;
                g_state.volume = frac;
                InvalidateRect(hWnd, NULL, FALSE);
            }
            // Delay Buttons: [-10] [-1] [+1] [+10] [0]
            else if (y >= 522 && y <= 548) {
                int dStartX = WIN_WIDTH - 210;
                for (int i = 0; i < 5; ++i) {
                    int bx = dStartX + i * 38;
                    if (x >= bx && x <= bx + 34) {
                        if (i == 0) g_state.delayMs -= 10;
                        else if (i == 1) g_state.delayMs -= 1;
                        else if (i == 2) g_state.delayMs += 1;
                        else if (i == 3) g_state.delayMs += 10;
                        else if (i == 4) g_state.delayMs = 0;
                        InvalidateRect(hWnd, NULL, FALSE);
                        break;
                    }
                }
            }
            return 0;
        }

        case WM_MOUSEMOVE: {
            if (wParam & MK_LBUTTON) {
                int x = GET_X_LPARAM(lParam);
                int y = GET_Y_LPARAM(lParam);
                if (g_state.isScrubbing) {
                    float frac = (float)(x - 18) / (float)(WIN_WIDTH - 36);
                    if (frac < 0.0f) frac = 0.0f;
                    if (frac > 1.0f) frac = 1.0f;
                    g_state.progressMs = static_cast<uint32_t>(frac * g_state.durationMs);
                    InvalidateRect(hWnd, NULL, FALSE);
                } else if (y >= 460 && y <= 485 && x >= 46 && x <= WIN_WIDTH - 46) {
                    float frac = (float)(x - 46) / (float)(WIN_WIDTH - 92);
                    if (frac < 0.0f) frac = 0.0f;
                    if (frac > 1.0f) frac = 1.0f;
                    g_state.volume = frac;
                    InvalidateRect(hWnd, NULL, FALSE);
                }
            }
            return 0;
        }

        case WM_LBUTTONUP:
            g_state.isScrubbing = false;
            return 0;

        case WM_PAINT: {
            PAINTSTRUCT ps;
            HDC hdc = BeginPaint(hWnd, &ps);
            
            // Double buffering to eliminate flicker
            HDC memDC = CreateCompatibleDC(hdc);
            HBITMAP memBitmap = CreateCompatibleBitmap(hdc, WIN_WIDTH, WIN_HEIGHT);
            HGDIOBJ oldBitmap = SelectObject(memDC, memBitmap);

            RenderUI(memDC, WIN_WIDTH, WIN_HEIGHT);

            BitBlt(hdc, 0, 0, WIN_WIDTH, WIN_HEIGHT, memDC, 0, 0, SRCCOPY);

            SelectObject(memDC, oldBitmap);
            DeleteObject(memBitmap);
            DeleteDC(memDC);
            
            EndPaint(hWnd, &ps);
            return 0;
        }

        case WM_ERASEBKGND:
            return 1;

        case WM_DESTROY:
            KillTimer(hWnd, 1);
            PostQuitMessage(0);
            return 0;
    }
    return DefWindowProc(hWnd, msg, wParam, lParam);
}

int WINAPI wWinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, PWSTR lpCmdLine, int nCmdShow) {
    WNDCLASSEX wc = {};
    wc.cbSize = sizeof(WNDCLASSEX);
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInstance;
    wc.lpszClassName = L"SendspinPlayerWnd";
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
    wc.style = CS_HREDRAW | CS_VREDRAW;

    if (!RegisterClassEx(&wc)) return 1;

    RECT rc = {0, 0, WIN_WIDTH, WIN_HEIGHT};
    AdjustWindowRect(&rc, WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX, FALSE);

    g_hWnd = CreateWindowEx(
        0,
        wc.lpszClassName,
        L"Sendspin Player (Windows UI Test Edition)",
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX,
        CW_USEDEFAULT, CW_USEDEFAULT,
        rc.right - rc.left, rc.bottom - rc.top,
        NULL, NULL, hInstance, NULL
    );

    if (!g_hWnd) return 1;

    // Start background audio thread
    g_audioRunning = true;
    g_hAudioThread = CreateThread(NULL, 0, AudioPlaybackThread, NULL, 0, NULL);

    ShowWindow(g_hWnd, nCmdShow);
    UpdateWindow(g_hWnd);

    MSG msg;
    while (GetMessage(&msg, NULL, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }

    g_audioRunning = false;
    if (g_hAudioThread) {
        WaitForSingleObject(g_hAudioThread, 1000);
        CloseHandle(g_hAudioThread);
        g_hAudioThread = NULL;
    }

    return (int)msg.wParam;
}
