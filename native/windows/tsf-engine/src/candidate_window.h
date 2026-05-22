// Candidate panel for the BurmeseIME TIP.
//
// A WS_POPUP top-level window — borderless, no-activate (the host
// keeps focus so keystrokes keep reaching us), topmost so it draws
// over the host app. Direct2D + DirectWrite for crisp Myanmar text
// shaping (Myanmar Text font ships with Windows 8+).
//
// One instance per TextService. Created lazily on the first
// non-empty candidate snapshot, hidden on commit/cancel/empty
// snapshot, destroyed on Deactivate.
//
// Selection state is duplicated here: the TIP-side selectedIndex_
// drives rendering, and on commit the TIP pushes it to the engine
// via worker.set_selected_sync before reading the commit surface.
// Keyboard navigation (Up/Down/PageUp/PageDown/Tab) is dispatched
// from key_event_sink.cpp into the moveSelection helpers below.

#pragma once

#include <Windows.h>
#include <d2d1.h>
#include <dwrite.h>

#include <string>
#include <vector>

#include "com_helpers.h"
#include "snapshot.h"

namespace burmese {

class CandidateWindow {
public:
    CandidateWindow() noexcept = default;
    ~CandidateWindow() noexcept;

    CandidateWindow(const CandidateWindow&) = delete;
    CandidateWindow& operator=(const CandidateWindow&) = delete;

    // Create the underlying HWND. Window starts hidden. `selfModule`
    // is the TIP DLL HMODULE (used for the window class hInstance
    // and to keep the class registration scoped to this DLL).
    bool create(HMODULE selfModule) noexcept;
    void destroy() noexcept;

    // Replace the candidate list with `snapshot.candidates` and
    // adopt `snapshot.selected` as the highlighted row. If the list
    // is empty the window is hidden; otherwise the window is shown
    // at the last position passed to setPosition() (or a default).
    void setCandidates(const ParsedSnapshot& snapshot) noexcept;

    // Move the window so its top-left sits just below `caretScreenRect`,
    // clamping inside the work area of the monitor that contains the
    // caret. Called after every fresh GetTextExt result.
    void setPositionBelow(const RECT& caretScreenRect) noexcept;

    void hide() noexcept;

    bool isVisible() const noexcept { return visible_; }
    int  selectedIndex() const noexcept { return selectedIndex_; }
    size_t candidateCount() const noexcept { return candidates_.size(); }

    // Navigation — invoked from the TIP's key event sink in response
    // to Up/Down/PageUp/PageDown/Tab/Shift-Tab. Each method moves
    // selection by one step and triggers a redraw. No-op when the
    // window is hidden or empty.
    void moveUp() noexcept;
    void moveDown() noexcept;
    void pageUp() noexcept;
    void pageDown() noexcept;

private:
    static LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM) noexcept;
    LRESULT handle(UINT msg, WPARAM wParam, LPARAM lParam) noexcept;

    // Resource lifecycle — D2D objects can be invalidated (lost
    // device, monitor change). create/release pair runs whenever the
    // render target needs to be regenerated.
    bool ensureDeviceIndependent() noexcept;
    bool ensureDeviceDependent() noexcept;
    void releaseDeviceDependent() noexcept;

    void render() noexcept;
    SIZE measureSize() const noexcept;
    void resizeToFit() noexcept;

    HWND hwnd_ = nullptr;
    HMODULE selfModule_ = nullptr;
    bool visible_ = false;

    std::vector<CandidateView> candidates_;
    int selectedIndex_ = 0;

    // Pagination: how many rows we draw at a time, and which page
    // window we're showing. Mirrors macOS/Linux page_size default of 9.
    static constexpr int kPageSize = 9;
    int pageOffset_ = 0;

    POINT lastAnchor_{ 100, 100 };

    // Direct2D + DirectWrite. ID2D1Factory / IDWriteFactory are
    // device-independent (created once). Render target + brushes
    // are device-dependent (recreated on D2DERR_RECREATE_TARGET).
    ID2D1Factory*           d2dFactory_      = nullptr;
    IDWriteFactory*         dwriteFactory_   = nullptr;
    IDWriteTextFormat*      textFormat_      = nullptr;
    IDWriteTextFormat*      indexFormat_     = nullptr;
    ID2D1HwndRenderTarget*  renderTarget_    = nullptr;
    ID2D1SolidColorBrush*   bgBrush_         = nullptr;
    ID2D1SolidColorBrush*   selectionBrush_  = nullptr;
    ID2D1SolidColorBrush*   textBrush_       = nullptr;
    ID2D1SolidColorBrush*   indexBrush_      = nullptr;
    ID2D1SolidColorBrush*   borderBrush_     = nullptr;
};

} // namespace burmese
