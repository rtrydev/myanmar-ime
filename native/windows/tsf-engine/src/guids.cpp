// Definitions of the public GUIDs declared in guids.h. Single owner so
// the linker has exactly one symbol per identity. Keep these values
// frozen across releases — every Windows install that has registered
// the TIP under HKLM\Software\Classes\CLSID is bound to them.

#include "guids.h"

#include <InitGuid.h>   // must be included exactly once before the DEFINE_GUIDs
#include <msctf.h>

namespace burmese {

// {4A524193-23CC-4586-9703-1FBD3ABE394F} — the TIP COM class.
extern const CLSID CLSID_TextService = {
    0x4A524193, 0x23CC, 0x4586,
    { 0x97, 0x03, 0x1F, 0xBD, 0x3A, 0xBE, 0x39, 0x4F }
};

// TSF profile GUID is conventionally the same as the CLSID; using one
// constant keeps the profile registration call obvious.
extern const GUID GUID_Profile = CLSID_TextService;

// {D19C8142-2BA3-44ED-902D-986BEC9265D2} — Compose/Roman toggle button.
extern const GUID GUID_LangBarItemCompose = {
    0xD19C8142, 0x2BA3, 0x44ED,
    { 0x90, 0x2D, 0x98, 0x6B, 0xEC, 0x92, 0x65, 0xD2 }
};

// {D8F7F27E-C2C8-4F18-B04D-088C8B08B86A} — preedit display attribute.
extern const GUID GUID_DisplayAttributeInput = {
    0xD8F7F27E, 0xC2C8, 0x4F18,
    { 0xB0, 0x4D, 0x08, 0x8C, 0x8B, 0x08, 0xB8, 0x6A }
};

} // namespace burmese
