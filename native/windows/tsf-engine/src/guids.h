// Public identity of the Myangler Burmese text service.
//
// These GUIDs are part of the published ABI:
//   - The CLSID identifies the TIP COM object to Windows. The MSI
//     installer writes it under HKLM\Software\Classes\CLSID\... and
//     ITfInputProcessorProfileMgr::RegisterProfile binds the Burmese
//     language ID to this CLSID. Changing it after first ship breaks
//     every installed user; treat it as never-change.
//   - LANGBAR_ITEM_BUTTON_COMPOSE identifies the Compose/Roman toggle
//     once the language bar item lands (deferred).
//   - DISPLAY_ATTRIBUTE_INPUT identifies the underline applied to the
//     preedit run once composition rendering lands (deferred).
//
// Defined as `extern const` so the .cpp file owns one initialiser and
// any number of translation units can reference them without ODR
// duplication.

#pragma once

#include <Unknwn.h>

namespace burmese {

extern const CLSID CLSID_TextService;
extern const GUID  GUID_Profile;                       // == CLSID_TextService
extern const GUID  GUID_LangBarItemCompose;
extern const GUID  GUID_DisplayAttributeInput;

// LANGID for Burmese (my-MM). Used at profile registration. LANG_BURMESE
// (0x55) + SUBLANG_DEFAULT (0x01) per the Windows National Language
// Support tables. The MSI custom-action that calls RegisterProfile
// passes this verbatim.
constexpr unsigned short kLangIdBurmese = 0x0455;

// Stable text-service name shown in the language bar. Keep ASCII for
// dev simplicity; localisation can come via a resource later.
inline constexpr wchar_t kTextServiceDescription[] = L"Myangler Burmese";

} // namespace burmese
