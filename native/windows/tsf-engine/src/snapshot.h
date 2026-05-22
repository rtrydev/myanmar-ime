// Parser for the JSON snapshot the FFI returns from
// burmese_engine_update. The wire format is the one produced by
// JSONEncoding.swift in the swift-shim:
//
//   {
//     "preedit": "minga",
//     "candidates": [
//       { "surface": "မင်္ဂ", "reading": "minga",
//         "source": "lexicon", "score": -3.21 }
//     ],
//     "selected": 0
//   }
//
// We only consume preedit + candidates[].surface + candidates[].reading
// + selected. source / score are skipped because the candidate window
// doesn't display them (could surface in the diagnostics tab later).
//
// Hand-rolled rather than pulling in a JSON library because the shape
// is small and stable — both sides of this contract live in one repo.

#pragma once

#include <string>
#include <vector>

namespace burmese {

struct CandidateView {
    std::string surface;   // UTF-8 Myanmar
    std::string reading;   // UTF-8 romanization
};

struct ParsedSnapshot {
    std::string preedit;
    std::vector<CandidateView> candidates;
    int selected = 0;
};

// Parse `json` into `out`. Returns true on success; on parse error
// `out` is partial / valid-but-stale and the caller should ignore it.
bool parseSnapshot(const std::string& json, ParsedSnapshot& out) noexcept;

} // namespace burmese
