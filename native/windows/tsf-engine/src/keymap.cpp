#include "keymap.h"

#include <Windows.h>
#include <cctype>

namespace burmese {

KeymapResult keymap_map(uint32_t vk, uint32_t modifiers, char shifted_char) noexcept {
    KeymapResult r{};
    r.action = KeymapAction::Ignore;

    // Defer to the client whenever Ctrl or Alt are held — same policy
    // as IBus / macOS. Shift alone is fine; it's how the user reaches
    // ':' or '+' on a US layout, and we need to let those through.
    if (modifiers & (kModCtrl | kModAlt)) {
        return r;
    }

    switch (vk) {
        case VK_BACK:        r.action = KeymapAction::Backspace; return r;
        case VK_ESCAPE:      r.action = KeymapAction::Cancel;    return r;
        case VK_RETURN:      r.action = KeymapAction::Commit;    return r;
        case VK_SPACE:       r.action = KeymapAction::Commit;
                             r.is_space = true;                  return r;

        case VK_UP:          r.action = KeymapAction::NavUp;       return r;
        case VK_DOWN:        r.action = KeymapAction::NavDown;     return r;
        case VK_PRIOR:       r.action = KeymapAction::NavPageUp;   return r;
        case VK_NEXT:        r.action = KeymapAction::NavPageDown; return r;
        case VK_HOME:        r.action = KeymapAction::NavHome;     return r;
        case VK_END:         r.action = KeymapAction::NavEnd;      return r;

        case VK_TAB:
            // Mirror macOS / Linux: Tab = next candidate (NavDown),
            // Shift+Tab = previous (NavUp).
            r.action = (modifiers & kModShift)
                ? KeymapAction::NavUp : KeymapAction::NavDown;
            return r;

        default: break;
    }

    // Printable ASCII path. The TIP-side adapter has already converted
    // the VK + shift state to an actual ASCII character; we just check
    // it's in the typeable range 0x21..0x7E. The engine's composing
    // buffer is always lowercased, mirroring the Linux side.
    const auto byte = static_cast<unsigned char>(shifted_char);
    if (byte >= 0x21 && byte <= 0x7E) {
        r.action = KeymapAction::Typeable;
        r.typed_char = static_cast<char>(std::tolower(byte));
        return r;
    }

    return r;
}

} // namespace burmese
