// Map a Windows virtual key + modifier flags to an engine action.
//
// Mirrors `native/linux/ibus-engine/src/keymap.{h,c}` exactly — the
// only differences are the input types (VK_* instead of IBus_KEY_*)
// and that Windows doesn't deliver bare modifier presses through the
// ITfKeyEventSink the way IBus delivers them through
// process_key_event, so KeymapAction::Modifier is unused on this side.
// Kept in the enum for source symmetry with Linux.

#pragma once

#include <cstdint>

namespace burmese {

enum class KeymapAction {
    Ignore,      // Pass through to the client.
    Modifier,    // Bare modifier press (kept for symmetry with Linux).
    Typeable,    // Append `typed_char` (lowercased ASCII) to the buffer.
    Backspace,
    Commit,      // Space / Return.
    Cancel,      // Escape.
    NavUp,
    NavDown,
    NavPageUp,
    NavPageDown,
    NavHome,
    NavEnd,
};

struct KeymapResult {
    KeymapAction action      = KeymapAction::Ignore;
    char         typed_char  = 0;        // valid only for Typeable
    bool         is_space    = false;    // true when Commit came from space
};

// Pure function. `vk` is a Windows virtual-key code (VK_A, VK_RETURN,
// VK_SPACE, ...). `modifiers` is a bitmask combining the values
// returned by GetKeyState() for shift/ctrl/alt — see kModShift / etc
// below. Returns Ignore when Ctrl or Alt are held so user shortcuts
// stay untouched, matching both the macOS controller and the Linux
// engine.
//
// The caller supplies `shifted_char` — the ASCII character the layout
// would produce for this VK + Shift combination — because Windows does
// NOT bake shift into the VK the way IBus bakes it into the keysym.
// ITfKeyEventSink::OnKeyDown gives us a VK and a GetKeyState-readable
// shift mask, so the TIP-side adapter translates that into a
// shifted_char via ToUnicodeEx and feeds it in here.
constexpr uint32_t kModShift = 1u << 0;
constexpr uint32_t kModCtrl  = 1u << 1;
constexpr uint32_t kModAlt   = 1u << 2;

KeymapResult keymap_map(uint32_t vk, uint32_t modifiers, char shifted_char) noexcept;

} // namespace burmese
