#include "candidate_window.h"

#include <algorithm>
#include <cwchar>

#include <dwmapi.h>

#include "log_file.h"

#pragma comment(lib, "dwmapi.lib")

namespace burmese {

namespace {

constexpr wchar_t kWindowClass[] = L"BurmeseIMETIP.CandWnd";

// Layout constants. Tuned so Myanmar Text — which has tall above /
// below baseline metrics — sits comfortably without clipping.
constexpr float kFontSizeBody    = 18.0f;
constexpr float kFontSizeIndex   = 13.0f;
constexpr float kFontSizeFooter  = 11.0f;
constexpr float kRowHeight       = 34.0f;
constexpr float kRowMargin       = 4.0f;   // left/right inset from the panel border
constexpr float kRowRadius       = 6.0f;   // rounded selection pill
constexpr float kPaddingX        = 14.0f;
constexpr float kPaddingY        = 8.0f;
constexpr float kFooterHeight    = 22.0f;
constexpr float kIndexWidth      = 22.0f;
constexpr float kMinWidth        = 240.0f;
constexpr float kMaxWidth        = 600.0f;

// DWM attribute IDs. These are guarded so that older Windows
// versions that don't recognise them simply return E_INVALIDARG and
// we fall back gracefully.
constexpr DWORD kDwmwaUseImmersiveDarkMode   = 20;
constexpr DWORD kDwmwaWindowCornerPreference = 33;
constexpr DWORD kDwmwaSystemBackdropType     = 38;
constexpr DWORD kDwmwcpRound                 = 2;
constexpr DWORD kDwmsbtTransientWindow       = 3;

std::wstring widenUtf8(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
    if (n <= 0) return {};
    std::wstring w(static_cast<size_t>(n - 1), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, w.data(), n);
    return w;
}

template <typename T>
void safeRelease(T*& p) noexcept {
    if (p) { p->Release(); p = nullptr; }
}

void registerOnce(HMODULE hInstance, WNDPROC proc) noexcept {
    WNDCLASSEXW wc{};
    wc.cbSize        = sizeof(wc);
    // CS_DROPSHADOW gives a small system shadow even on hosts that
    // ignore the DWM transient-window backdrop; cheap fallback.
    wc.style         = CS_HREDRAW | CS_VREDRAW | CS_DROPSHADOW;
    wc.lpfnWndProc   = proc;
    wc.hInstance     = static_cast<HINSTANCE>(hInstance);
    wc.hCursor       = LoadCursor(nullptr, IDC_ARROW);
    wc.lpszClassName = kWindowClass;
    RegisterClassExW(&wc);   // duplicate registration is harmless
}

// Read HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\
// Personalize::AppsUseLightTheme. Default to light when the value
// is missing (matches Windows' own default).
bool readSystemIsDark() noexcept {
    HKEY hk;
    LONG s = RegOpenKeyExW(
        HKEY_CURRENT_USER,
        L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
        0, KEY_READ, &hk);
    if (s != ERROR_SUCCESS) return false;
    DWORD value = 1, size = sizeof(value), type = 0;
    s = RegQueryValueExW(hk, L"AppsUseLightTheme", nullptr, &type,
                         reinterpret_cast<BYTE*>(&value), &size);
    RegCloseKey(hk);
    if (s != ERROR_SUCCESS || type != REG_DWORD) return false;
    return value == 0;
}

// DWM accent stored as 0xAABBGGRR. Translate to D2D1_COLOR_F.
D2D1_COLOR_F readSystemAccent() noexcept {
    HKEY hk;
    LONG s = RegOpenKeyExW(HKEY_CURRENT_USER,
                           L"Software\\Microsoft\\Windows\\DWM",
                           0, KEY_READ, &hk);
    if (s != ERROR_SUCCESS) {
        return D2D1::ColorF(0x0067C0); // Win11 default blue
    }
    DWORD packed = 0xFF0067C0, size = sizeof(packed), type = 0;
    s = RegQueryValueExW(hk, L"AccentColor", nullptr, &type,
                         reinterpret_cast<BYTE*>(&packed), &size);
    RegCloseKey(hk);
    if (s != ERROR_SUCCESS || type != REG_DWORD) {
        return D2D1::ColorF(0x0067C0);
    }
    BYTE b = static_cast<BYTE>((packed >> 16) & 0xFF);
    BYTE g = static_cast<BYTE>((packed >>  8) & 0xFF);
    BYTE r = static_cast<BYTE>( packed        & 0xFF);
    return D2D1::ColorF(r / 255.0f, g / 255.0f, b / 255.0f, 1.0f);
}

// Read the user's CandidatePageSize. The Preferences app writes
// this under HKCU\Software\Myangler\BurmeseIME, matching what
// settings.cpp manages for the engine itself.
int readPageSizeFromRegistry(int fallback) noexcept {
    HKEY hk;
    LONG s = RegOpenKeyExW(HKEY_CURRENT_USER,
                           L"Software\\Myangler\\BurmeseIME",
                           0, KEY_READ, &hk);
    if (s != ERROR_SUCCESS) return fallback;
    DWORD value = static_cast<DWORD>(fallback), size = sizeof(value), type = 0;
    s = RegQueryValueExW(hk, L"CandidatePageSize", nullptr, &type,
                         reinterpret_cast<BYTE*>(&value), &size);
    RegCloseKey(hk);
    if (s != ERROR_SUCCESS || type != REG_DWORD) return fallback;
    int v = static_cast<int>(value);
    if (v < 1) v = 1;
    if (v > 24) v = 24;
    return v;
}

} // namespace

CandidateWindow::~CandidateWindow() noexcept { destroy(); }

bool CandidateWindow::create(HMODULE selfModule) noexcept {
    if (hwnd_) return true;
    selfModule_ = selfModule;
    registerOnce(selfModule_, &CandidateWindow::WndProc);

    // Refresh theme before window creation so initial measurement
    // sees correct color choices.
    refreshTheme();
    refreshPageSize();

    hwnd_ = CreateWindowExW(
        // NOACTIVATE: keystrokes keep flowing to the host while we're
        // visible. TOOLWINDOW: stays out of the alt-tab list and Taskbar.
        // TOPMOST: draws above the host's normal layer.
        WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
        kWindowClass, L"",
        // WS_POPUP without WS_BORDER — Win11 rounded corners only
        // apply on top-level windows that don't carry a 1-px chrome
        // border. We draw the border ourselves in D2D so it picks up
        // the theme accent.
        WS_POPUP,
        100, 100, static_cast<int>(kMinWidth),
        static_cast<int>(pageSize_ * kRowHeight + 2 * kPaddingY),
        nullptr, nullptr,
        static_cast<HINSTANCE>(selfModule_),
        this);

    log_line(L"CandidateWindow::create hwnd=%p gle=%u",
             static_cast<void*>(hwnd_),
             hwnd_ ? 0u : GetLastError());
    if (!hwnd_) return false;

    applyDwmAttributes();   // round corners + dark mode hint
    return ensureDeviceIndependent();
}

void CandidateWindow::destroy() noexcept {
    releaseDeviceDependent();
    safeRelease(textFormat_);
    safeRelease(indexFormat_);
    safeRelease(dwriteFactory_);
    safeRelease(d2dFactory_);
    if (hwnd_) {
        DestroyWindow(hwnd_);
        hwnd_ = nullptr;
    }
    visible_ = false;
}

void CandidateWindow::setCandidates(const ParsedSnapshot& snapshot) noexcept {
    // Re-read user preferences before deciding layout. Cheap (one
    // registry read on a hot key), keeps us responsive to settings.
    refreshPageSize();

    candidates_       = snapshot.candidates;
    selectedIndex_    = std::clamp(snapshot.selected, 0,
                                   static_cast<int>(candidates_.size()) - 1);
    if (selectedIndex_ < 0) selectedIndex_ = 0;
    pageOffset_       = (selectedIndex_ / pageSize_) * pageSize_;

    if (candidates_.empty()) {
        hide();
        return;
    }
    if (!hwnd_) {
        log_line(L"CandidateWindow::setCandidates hwnd_ is null — snapshot has %zu candidates but the window was never created",
                 candidates_.size());
        return;
    }
    resizeToFit();
    if (!visible_) {
        ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
        visible_ = true;
    }
    // Re-assert HWND_TOPMOST on every snapshot, not just on
    // setPositionBelow. setPositionBelow only runs if the host's
    // GetTextExt succeeded — in immersive shell contexts (Win11
    // Start Menu / Search Bar) GetTextExt commonly returns
    // TF_E_NOLAYOUT, so without this re-assertion the window is
    // ShowWindow'd but its z-order never gets explicitly raised,
    // and the shell surface ends up drawing over it. Cheap on the
    // hosts that don't need it (already topmost).
    SetWindowPos(hwnd_, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    InvalidateRect(hwnd_, nullptr, FALSE);

    BOOL osVisible = IsWindowVisible(hwnd_);
    RECT wr{};
    GetWindowRect(hwnd_, &wr);
    log_line(L"CandidateWindow::setCandidates shown count=%zu sel=%d osVisible=%d rect=(%d,%d %dx%d) pageSize=%d",
             candidates_.size(), selectedIndex_, osVisible ? 1 : 0,
             wr.left, wr.top, wr.right - wr.left, wr.bottom - wr.top,
             pageSize_);
}

void CandidateWindow::setPositionBelow(const RECT& caret) noexcept {
    if (!hwnd_) return;
    // Anchor the panel just below the caret rect. The panel hugs
    // the caret horizontally and falls below vertically; if there
    // isn't room below, flip above. Clamp within the monitor work
    // area so we never render off-screen.
    SIZE sz = measureSize();
    POINT anchor{ caret.left, caret.bottom + 4 };

    HMONITOR mon = MonitorFromPoint(anchor, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi{ sizeof(mi) };
    GetMonitorInfoW(mon, &mi);
    const RECT& work = mi.rcWork;

    if (anchor.x + sz.cx > work.right)  anchor.x = work.right - sz.cx;
    if (anchor.x < work.left)           anchor.x = work.left;
    if (anchor.y + sz.cy > work.bottom) {
        // Flip above the caret instead.
        anchor.y = caret.top - sz.cy - 4;
        if (anchor.y < work.top) anchor.y = work.top;
    }

    lastAnchor_ = anchor;
    SetWindowPos(hwnd_, HWND_TOPMOST, anchor.x, anchor.y, sz.cx, sz.cy,
                 SWP_NOACTIVATE);
    log_line(L"CandidateWindow::setPositionBelow anchor=(%d,%d) size=%dx%d",
             anchor.x, anchor.y, sz.cx, sz.cy);
}

void CandidateWindow::hide() noexcept {
    if (!hwnd_ || !visible_) {
        visible_ = false;
        return;
    }
    ShowWindow(hwnd_, SW_HIDE);
    visible_ = false;
}

// ---- Navigation ---------------------------------------------------

void CandidateWindow::moveUp() noexcept {
    if (candidates_.empty()) return;
    selectedIndex_ = (selectedIndex_ - 1 + static_cast<int>(candidates_.size()))
                     % static_cast<int>(candidates_.size());
    pageOffset_ = (selectedIndex_ / pageSize_) * pageSize_;
    if (hwnd_) InvalidateRect(hwnd_, nullptr, FALSE);
}

void CandidateWindow::moveDown() noexcept {
    if (candidates_.empty()) return;
    selectedIndex_ = (selectedIndex_ + 1) % static_cast<int>(candidates_.size());
    pageOffset_ = (selectedIndex_ / pageSize_) * pageSize_;
    if (hwnd_) InvalidateRect(hwnd_, nullptr, FALSE);
}

void CandidateWindow::pageUp() noexcept {
    if (candidates_.empty()) return;
    selectedIndex_ = std::max(0, selectedIndex_ - pageSize_);
    pageOffset_ = (selectedIndex_ / pageSize_) * pageSize_;
    if (hwnd_) InvalidateRect(hwnd_, nullptr, FALSE);
}

void CandidateWindow::pageDown() noexcept {
    if (candidates_.empty()) return;
    selectedIndex_ = std::min(static_cast<int>(candidates_.size()) - 1,
                              selectedIndex_ + pageSize_);
    pageOffset_ = (selectedIndex_ / pageSize_) * pageSize_;
    if (hwnd_) InvalidateRect(hwnd_, nullptr, FALSE);
}

// ---- Theming ------------------------------------------------------

void CandidateWindow::refreshTheme() noexcept {
    isDark_ = readSystemIsDark();
    D2D1_COLOR_F accent = readSystemAccent();

    if (isDark_) {
        // Win11 dark popup palette. Background sits a notch darker
        // than the system accent; selection uses a low-alpha accent
        // fill so the candidate glyph still reads cleanly above it.
        palette_.background       = D2D1::ColorF(0x2C2C2C, 1.0f);
        palette_.selection        = D2D1::ColorF(accent.r, accent.g, accent.b, 0.32f);
        palette_.selectionAccent  = accent;
        palette_.text             = D2D1::ColorF(0xFFFFFF, 1.0f);
        palette_.selectedText     = D2D1::ColorF(0xFFFFFF, 1.0f);
        palette_.index            = D2D1::ColorF(0xB8B8B8, 1.0f);
        palette_.border           = D2D1::ColorF(0xFFFFFF, 0.10f);
        palette_.footer           = D2D1::ColorF(0x8C8C8C, 1.0f);
    } else {
        palette_.background       = D2D1::ColorF(0xFBFBFB, 1.0f);
        palette_.selection        = D2D1::ColorF(accent.r, accent.g, accent.b, 0.16f);
        palette_.selectionAccent  = accent;
        palette_.text             = D2D1::ColorF(0x1A1A1A, 1.0f);
        palette_.selectedText     = D2D1::ColorF(0x1A1A1A, 1.0f);
        palette_.index            = D2D1::ColorF(0x6B6B6B, 1.0f);
        palette_.border           = D2D1::ColorF(0x000000, 0.10f);
        palette_.footer           = D2D1::ColorF(0x6B6B6B, 1.0f);
    }

    // Brushes are device-dependent; drop them so the next render
    // recreates them with the new palette.
    releaseDeviceDependent();
}

void CandidateWindow::applyDwmAttributes() noexcept {
    if (!hwnd_) return;
    // Immersive dark mode controls the small DWM shadow used for
    // tooltips / popups; matters most on Win10. Older builds return
    // an error which is fine.
    BOOL dark = isDark_ ? TRUE : FALSE;
    DwmSetWindowAttribute(hwnd_, kDwmwaUseImmersiveDarkMode, &dark, sizeof(dark));

    // Win11 rounded corners. DWMWCP_ROUND = 2; system picks the
    // small-popup radius (matches WinUI flyouts).
    DWORD corner = kDwmwcpRound;
    DwmSetWindowAttribute(hwnd_, kDwmwaWindowCornerPreference, &corner, sizeof(corner));

    // Transient-window backdrop (Win11 22H2+). Slight Mica blur for
    // popups; older builds ignore the attribute.
    DWORD backdrop = kDwmsbtTransientWindow;
    DwmSetWindowAttribute(hwnd_, kDwmwaSystemBackdropType, &backdrop, sizeof(backdrop));
}

void CandidateWindow::refreshPageSize() noexcept {
    pageSize_ = readPageSizeFromRegistry(kDefaultPageSize);
}

// ---- D2D / DWrite -------------------------------------------------

bool CandidateWindow::ensureDeviceIndependent() noexcept {
    if (!d2dFactory_) {
        HRESULT hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
                                       &d2dFactory_);
        if (FAILED(hr)) return false;
    }
    if (!dwriteFactory_) {
        HRESULT hr = DWriteCreateFactory(
            DWRITE_FACTORY_TYPE_SHARED,
            __uuidof(IDWriteFactory),
            reinterpret_cast<IUnknown**>(&dwriteFactory_));
        if (FAILED(hr)) return false;
    }
    if (!textFormat_) {
        HRESULT hr = dwriteFactory_->CreateTextFormat(
            L"Myanmar Text",
            nullptr,
            DWRITE_FONT_WEIGHT_NORMAL,
            DWRITE_FONT_STYLE_NORMAL,
            DWRITE_FONT_STRETCH_NORMAL,
            kFontSizeBody,
            L"en-us",
            &textFormat_);
        if (FAILED(hr)) return false;
        textFormat_->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_LEADING);
        textFormat_->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    }
    if (!indexFormat_) {
        HRESULT hr = dwriteFactory_->CreateTextFormat(
            L"Segoe UI Variable, Segoe UI",
            nullptr,
            DWRITE_FONT_WEIGHT_SEMI_BOLD,
            DWRITE_FONT_STYLE_NORMAL,
            DWRITE_FONT_STRETCH_NORMAL,
            kFontSizeIndex,
            L"en-us",
            &indexFormat_);
        if (FAILED(hr)) return false;
        indexFormat_->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_LEADING);
        indexFormat_->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    }
    return true;
}

bool CandidateWindow::ensureDeviceDependent() noexcept {
    if (renderTarget_) return true;
    if (!hwnd_ || !d2dFactory_) return false;

    RECT rc;
    GetClientRect(hwnd_, &rc);
    D2D1_SIZE_U size = D2D1::SizeU(
        static_cast<UINT32>(rc.right - rc.left),
        static_cast<UINT32>(rc.bottom - rc.top));

    HRESULT hr = d2dFactory_->CreateHwndRenderTarget(
        D2D1::RenderTargetProperties(),
        D2D1::HwndRenderTargetProperties(hwnd_, size),
        &renderTarget_);
    if (FAILED(hr)) return false;

    renderTarget_->CreateSolidColorBrush(palette_.background,      &bgBrush_);
    renderTarget_->CreateSolidColorBrush(palette_.selection,       &selectionBrush_);
    renderTarget_->CreateSolidColorBrush(palette_.selectionAccent, &selectionAccent_);
    renderTarget_->CreateSolidColorBrush(palette_.text,            &textBrush_);
    renderTarget_->CreateSolidColorBrush(palette_.selectedText,    &selTextBrush_);
    renderTarget_->CreateSolidColorBrush(palette_.index,           &indexBrush_);
    renderTarget_->CreateSolidColorBrush(palette_.border,          &borderBrush_);
    renderTarget_->CreateSolidColorBrush(palette_.footer,          &footerBrush_);
    return true;
}

void CandidateWindow::releaseDeviceDependent() noexcept {
    safeRelease(footerBrush_);
    safeRelease(borderBrush_);
    safeRelease(indexBrush_);
    safeRelease(selTextBrush_);
    safeRelease(textBrush_);
    safeRelease(selectionAccent_);
    safeRelease(selectionBrush_);
    safeRelease(bgBrush_);
    safeRelease(renderTarget_);
}

// ---- Layout -------------------------------------------------------

SIZE CandidateWindow::measureSize() const noexcept {
    int rows = std::min<int>(pageSize_, static_cast<int>(candidates_.size()));
    if (rows < 1) rows = 1;
    int height = static_cast<int>(2 * kPaddingY + rows * kRowHeight);

    // Reserve a footer band for the page indicator when the
    // candidate list exceeds the visible page.
    if (static_cast<int>(candidates_.size()) > pageSize_) {
        height += static_cast<int>(kFooterHeight);
    }

    // Width: rough heuristic — assume Myanmar glyphs average 16 px
    // at our font size. Real DWrite layout would be exact but the
    // panel can be a bit wider than strictly needed without harm.
    float widest = 0;
    for (int i = pageOffset_, end = std::min<int>(pageOffset_ + pageSize_,
                                                  static_cast<int>(candidates_.size()));
         i < end; ++i) {
        const auto& c = candidates_[static_cast<size_t>(i)];
        const float approx = 2 * kPaddingX + kIndexWidth
            + static_cast<float>(c.surface.size()) * 13.0f;
        if (approx > widest) widest = approx;
    }
    float w = std::clamp(widest, kMinWidth, kMaxWidth);
    return SIZE{ static_cast<int>(w), height };
}

void CandidateWindow::resizeToFit() noexcept {
    if (!hwnd_) return;
    SIZE sz = measureSize();
    RECT cur;
    GetWindowRect(hwnd_, &cur);
    if (sz.cx != (cur.right - cur.left) || sz.cy != (cur.bottom - cur.top)) {
        SetWindowPos(hwnd_, nullptr, 0, 0, sz.cx, sz.cy,
                     SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
        if (renderTarget_) {
            renderTarget_->Resize(D2D1::SizeU(
                static_cast<UINT32>(sz.cx),
                static_cast<UINT32>(sz.cy)));
        }
    }
}

// ---- Painting -----------------------------------------------------

void CandidateWindow::render() noexcept {
    if (!ensureDeviceDependent()) return;

    renderTarget_->BeginDraw();
    renderTarget_->Clear(palette_.background);

    D2D1_SIZE_F sz = renderTarget_->GetSize();

    // Subtle inner border. We draw a 1-px rounded rect just inside
    // the client edge so DWM's rounded-corner clip doesn't chop the
    // stroke. Falls within the 6-px corner radius DWM picks for
    // popup windows.
    D2D1_ROUNDED_RECT outer = D2D1::RoundedRect(
        D2D1::RectF(0.5f, 0.5f, sz.width - 0.5f, sz.height - 0.5f),
        7.0f, 7.0f);
    renderTarget_->DrawRoundedRectangle(outer, borderBrush_, 1.0f);

    const int first = pageOffset_;
    const int last  = std::min<int>(first + pageSize_,
                                    static_cast<int>(candidates_.size()));
    const int total = static_cast<int>(candidates_.size());
    const bool showFooter = total > pageSize_;
    const float bodyTop   = kPaddingY;

    for (int i = first; i < last; ++i) {
        const int row = i - first;
        const float top    = bodyTop + row * kRowHeight;
        const float bottom = top + kRowHeight;

        if (i == selectedIndex_) {
            // Filled rounded pill in low-alpha accent. The accent
            // sliver on the leading edge anchors the eye without
            // overwhelming the text.
            D2D1_ROUNDED_RECT sel = D2D1::RoundedRect(
                D2D1::RectF(kRowMargin, top + 2,
                            sz.width - kRowMargin, bottom - 2),
                kRowRadius, kRowRadius);
            renderTarget_->FillRoundedRectangle(sel, selectionBrush_);

            // Accent sliver on the left edge.
            D2D1_ROUNDED_RECT pip = D2D1::RoundedRect(
                D2D1::RectF(kRowMargin + 2, top + 8,
                            kRowMargin + 5, bottom - 8),
                1.5f, 1.5f);
            renderTarget_->FillRoundedRectangle(pip, selectionAccent_);
        }

        wchar_t idx[4];
        std::swprintf(idx, 4, L"%d", row + 1);
        renderTarget_->DrawTextW(
            idx, static_cast<UINT32>(std::wcslen(idx)),
            indexFormat_,
            D2D1::RectF(kPaddingX, top, kPaddingX + kIndexWidth, bottom),
            indexBrush_);

        std::wstring surface = widenUtf8(candidates_[static_cast<size_t>(i)].surface);
        if (!surface.empty()) {
            auto* fg = (i == selectedIndex_) ? selTextBrush_ : textBrush_;
            renderTarget_->DrawTextW(
                surface.c_str(),
                static_cast<UINT32>(surface.size()),
                textFormat_,
                D2D1::RectF(kPaddingX + kIndexWidth + 6,
                            top,
                            sz.width - kPaddingX,
                            bottom),
                fg);
        }
    }

    if (showFooter) {
        // "page X of Y · N candidates" — single line at the bottom.
        const int pages   = (total + pageSize_ - 1) / pageSize_;
        const int curPage = (pageOffset_ / pageSize_) + 1;
        wchar_t footer[64];
        std::swprintf(footer, 64, L"page %d/%d  ·  %d candidates",
                      curPage, pages, total);

        IDWriteTextFormat* footerFormat = nullptr;
        dwriteFactory_->CreateTextFormat(
            L"Segoe UI Variable, Segoe UI",
            nullptr,
            DWRITE_FONT_WEIGHT_NORMAL,
            DWRITE_FONT_STYLE_NORMAL,
            DWRITE_FONT_STRETCH_NORMAL,
            kFontSizeFooter,
            L"en-us",
            &footerFormat);
        if (footerFormat) {
            footerFormat->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_TRAILING);
            footerFormat->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);

            const float fy = sz.height - kFooterHeight;
            // Thin top border on the footer band.
            renderTarget_->DrawLine(
                D2D1::Point2F(kRowMargin + 2, fy),
                D2D1::Point2F(sz.width - kRowMargin - 2, fy),
                borderBrush_, 1.0f);

            renderTarget_->DrawTextW(
                footer, static_cast<UINT32>(std::wcslen(footer)),
                footerFormat,
                D2D1::RectF(kPaddingX, fy, sz.width - kPaddingX, sz.height),
                footerBrush_);
            footerFormat->Release();
        }
    }

    HRESULT hr = renderTarget_->EndDraw();
    if (hr == D2DERR_RECREATE_TARGET) {
        releaseDeviceDependent();
    }
}

// ---- Window proc --------------------------------------------------

LRESULT CALLBACK CandidateWindow::WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) noexcept {
    if (msg == WM_NCCREATE) {
        auto* cs = reinterpret_cast<CREATESTRUCT*>(lParam);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA,
            reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
        return TRUE;
    }
    auto* self = reinterpret_cast<CandidateWindow*>(
        GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (!self) return DefWindowProcW(hwnd, msg, wParam, lParam);
    return self->handle(msg, wParam, lParam);
}

LRESULT CandidateWindow::handle(UINT msg, WPARAM wParam, LPARAM lParam) noexcept {
    switch (msg) {
        case WM_PAINT: {
            PAINTSTRUCT ps;
            BeginPaint(hwnd_, &ps);
            render();
            EndPaint(hwnd_, &ps);
            return 0;
        }
        case WM_SIZE: {
            if (renderTarget_) {
                renderTarget_->Resize(D2D1::SizeU(LOWORD(lParam), HIWORD(lParam)));
            }
            return 0;
        }
        case WM_DISPLAYCHANGE: {
            InvalidateRect(hwnd_, nullptr, FALSE);
            return 0;
        }
        // Personalize key changed or any system setting did. WPF /
        // WinUI listen on the same message; we rebuild the palette
        // and force a redraw. The lParam string identifies WHICH
        // setting changed, but we don't bother filtering — re-reading
        // the registry is cheap and the user-perceptible win of
        // staying in sync outweighs the few microseconds.
        case WM_SETTINGCHANGE: {
            refreshTheme();
            refreshPageSize();
            applyDwmAttributes();
            InvalidateRect(hwnd_, nullptr, FALSE);
            return 0;
        }
        // DWM color (accent) changed.
        case 0x0320 /* WM_DWMCOLORIZATIONCOLORCHANGED */: {
            refreshTheme();
            InvalidateRect(hwnd_, nullptr, FALSE);
            return 0;
        }
        case WM_ERASEBKGND:
            // We paint the whole client area in WM_PAINT; suppress
            // GDI erase to avoid the flash.
            return 1;
        // Mouse activation: clicking the panel must not take focus
        // away from the host text field. MA_NOACTIVATE prevents
        // activation; we still get mouse events.
        case WM_MOUSEACTIVATE:
            return MA_NOACTIVATE;
        default:
            return DefWindowProcW(hwnd_, msg, wParam, lParam);
    }
}

} // namespace burmese
