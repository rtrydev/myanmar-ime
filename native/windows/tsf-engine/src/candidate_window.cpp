#include "candidate_window.h"

#include <algorithm>
#include <cwchar>

namespace burmese {

namespace {

constexpr wchar_t kWindowClass[] = L"BurmeseIMETIP.CandWnd";

// Layout constants. Tuned to give Myanmar text room to breathe at
// 14-pt body / 12-pt index — Myanmar Text has tall above/below
// baseline metrics so rows need a bit more height than Latin would.
constexpr float kFontSizeBody    = 18.0f;
constexpr float kFontSizeIndex   = 14.0f;
constexpr float kRowHeight       = 30.0f;
constexpr float kPaddingX        = 12.0f;
constexpr float kPaddingY        = 6.0f;
constexpr float kIndexWidth      = 22.0f;
constexpr float kMinWidth        = 220.0f;
constexpr float kMaxWidth        = 600.0f;

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
    wc.style         = CS_HREDRAW | CS_VREDRAW | CS_DROPSHADOW;
    wc.lpfnWndProc   = proc;
    wc.hInstance     = static_cast<HINSTANCE>(hInstance);
    wc.hCursor       = LoadCursor(nullptr, IDC_ARROW);
    wc.lpszClassName = kWindowClass;
    RegisterClassExW(&wc);   // duplicate registration is harmless
}

} // namespace

CandidateWindow::~CandidateWindow() noexcept { destroy(); }

bool CandidateWindow::create(HMODULE selfModule) noexcept {
    if (hwnd_) return true;
    selfModule_ = selfModule;
    registerOnce(selfModule_, &CandidateWindow::WndProc);

    hwnd_ = CreateWindowExW(
        // NOACTIVATE: keystrokes keep flowing to the host while we're
        // visible. TOOLWINDOW: stays out of the alt-tab list and Taskbar.
        // TOPMOST: draws above the host's normal layer.
        WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
        kWindowClass, L"",
        WS_POPUP | WS_BORDER,
        100, 100, static_cast<int>(kMinWidth),
        static_cast<int>(kPageSize * kRowHeight + 2 * kPaddingY),
        nullptr, nullptr,
        static_cast<HINSTANCE>(selfModule_),
        this);

    if (!hwnd_) return false;
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
    candidates_       = snapshot.candidates;
    selectedIndex_    = std::clamp(snapshot.selected, 0,
                                   static_cast<int>(candidates_.size()) - 1);
    if (selectedIndex_ < 0) selectedIndex_ = 0;
    pageOffset_       = (selectedIndex_ / kPageSize) * kPageSize;

    if (candidates_.empty()) {
        hide();
        return;
    }
    if (!hwnd_) return;
    resizeToFit();
    if (!visible_) {
        ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
        visible_ = true;
    }
    InvalidateRect(hwnd_, nullptr, FALSE);
}

void CandidateWindow::setPositionBelow(const RECT& caret) noexcept {
    if (!hwnd_) return;
    // Anchor the panel just below the caret rect. The panel hugs
    // the caret horizontally and falls below vertically; if there
    // isn't room below, flip above. Clamp within the monitor work
    // area so we never render off-screen.
    SIZE sz = measureSize();
    POINT anchor{ caret.left, caret.bottom + 2 };

    HMONITOR mon = MonitorFromPoint(anchor, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi{ sizeof(mi) };
    GetMonitorInfoW(mon, &mi);
    const RECT& work = mi.rcWork;

    if (anchor.x + sz.cx > work.right)  anchor.x = work.right - sz.cx;
    if (anchor.x < work.left)           anchor.x = work.left;
    if (anchor.y + sz.cy > work.bottom) {
        // Flip above the caret instead.
        anchor.y = caret.top - sz.cy - 2;
        if (anchor.y < work.top) anchor.y = work.top;
    }

    lastAnchor_ = anchor;
    SetWindowPos(hwnd_, HWND_TOPMOST, anchor.x, anchor.y, sz.cx, sz.cy,
                 SWP_NOACTIVATE);
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
    pageOffset_ = (selectedIndex_ / kPageSize) * kPageSize;
    if (hwnd_) InvalidateRect(hwnd_, nullptr, FALSE);
}

void CandidateWindow::moveDown() noexcept {
    if (candidates_.empty()) return;
    selectedIndex_ = (selectedIndex_ + 1) % static_cast<int>(candidates_.size());
    pageOffset_ = (selectedIndex_ / kPageSize) * kPageSize;
    if (hwnd_) InvalidateRect(hwnd_, nullptr, FALSE);
}

void CandidateWindow::pageUp() noexcept {
    if (candidates_.empty()) return;
    selectedIndex_ = std::max(0, selectedIndex_ - kPageSize);
    pageOffset_ = (selectedIndex_ / kPageSize) * kPageSize;
    if (hwnd_) InvalidateRect(hwnd_, nullptr, FALSE);
}

void CandidateWindow::pageDown() noexcept {
    if (candidates_.empty()) return;
    selectedIndex_ = std::min(static_cast<int>(candidates_.size()) - 1,
                              selectedIndex_ + kPageSize);
    pageOffset_ = (selectedIndex_ / kPageSize) * kPageSize;
    if (hwnd_) InvalidateRect(hwnd_, nullptr, FALSE);
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
            L"Segoe UI",
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

    renderTarget_->CreateSolidColorBrush(D2D1::ColorF(0xFFFFFF), &bgBrush_);
    renderTarget_->CreateSolidColorBrush(D2D1::ColorF(0xCCE5FF), &selectionBrush_);
    renderTarget_->CreateSolidColorBrush(D2D1::ColorF(0x1F1F1F), &textBrush_);
    renderTarget_->CreateSolidColorBrush(D2D1::ColorF(0x6B6B6B), &indexBrush_);
    renderTarget_->CreateSolidColorBrush(D2D1::ColorF(0xCCCCCC), &borderBrush_);
    return true;
}

void CandidateWindow::releaseDeviceDependent() noexcept {
    safeRelease(borderBrush_);
    safeRelease(indexBrush_);
    safeRelease(textBrush_);
    safeRelease(selectionBrush_);
    safeRelease(bgBrush_);
    safeRelease(renderTarget_);
}

// ---- Layout -------------------------------------------------------

SIZE CandidateWindow::measureSize() const noexcept {
    int rows = std::min<int>(kPageSize, static_cast<int>(candidates_.size()));
    if (rows < 1) rows = 1;
    int height = static_cast<int>(2 * kPaddingY + rows * kRowHeight);

    // Width: rough heuristic — assume Myanmar glyphs average 24 px
    // at our font size. Real DWrite layout would be exact but we
    // don't need to be precise; the window can be wider than
    // strictly needed without harming usability.
    float widest = 0;
    for (int i = pageOffset_, end = std::min<int>(pageOffset_ + kPageSize,
                                                  static_cast<int>(candidates_.size()));
         i < end; ++i) {
        const auto& c = candidates_[static_cast<size_t>(i)];
        const float approx = 2 * kPaddingX + kIndexWidth
            + static_cast<float>(c.surface.size()) * 14.0f;
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
    renderTarget_->Clear(D2D1::ColorF(0xFFFFFF));

    D2D1_SIZE_F sz = renderTarget_->GetSize();
    renderTarget_->DrawRectangle(
        D2D1::RectF(0.5f, 0.5f, sz.width - 0.5f, sz.height - 0.5f),
        borderBrush_,
        1.0f);

    const int first = pageOffset_;
    const int last  = std::min<int>(first + kPageSize,
                                    static_cast<int>(candidates_.size()));

    for (int i = first; i < last; ++i) {
        const int row = i - first;
        const float top    = kPaddingY + row * kRowHeight;
        const float bottom = top + kRowHeight;

        if (i == selectedIndex_) {
            renderTarget_->FillRectangle(
                D2D1::RectF(kPaddingX * 0.5f, top, sz.width - kPaddingX * 0.5f, bottom),
                selectionBrush_);
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
            renderTarget_->DrawTextW(
                surface.c_str(),
                static_cast<UINT32>(surface.size()),
                textFormat_,
                D2D1::RectF(kPaddingX + kIndexWidth + 6,
                            top,
                            sz.width - kPaddingX,
                            bottom),
                textBrush_);
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
