#include "snapshot.h"

#include <cctype>

namespace burmese {

namespace {

class Parser {
public:
    Parser(const char* p, size_t n) noexcept : p_(p), end_(p + n) {}

    void skip_ws() noexcept {
        while (p_ < end_ && (*p_ == ' ' || *p_ == '\t' || *p_ == '\n' || *p_ == '\r')) ++p_;
    }

    bool peek(char c) noexcept {
        skip_ws();
        return p_ < end_ && *p_ == c;
    }

    bool consume(char c) noexcept {
        skip_ws();
        if (p_ >= end_ || *p_ != c) return false;
        ++p_;
        return true;
    }

    bool parse_string(std::string& out) {
        skip_ws();
        if (!consume('"')) return false;
        out.clear();
        while (p_ < end_ && *p_ != '"') {
            if (*p_ == '\\') {
                ++p_;
                if (p_ >= end_) return false;
                switch (*p_) {
                    case '"':  out += '"';  break;
                    case '\\': out += '\\'; break;
                    case '/':  out += '/';  break;
                    case 'n':  out += '\n'; break;
                    case 't':  out += '\t'; break;
                    case 'r':  out += '\r'; break;
                    case 'b':  out += '\b'; break;
                    case 'f':  out += '\f'; break;
                    case 'u': {
                        if (p_ + 4 >= end_) return false;
                        unsigned int code = 0;
                        for (int i = 1; i <= 4; ++i) {
                            char c = p_[i];
                            code <<= 4;
                            if (c >= '0' && c <= '9') code |= c - '0';
                            else if (c >= 'a' && c <= 'f') code |= 10 + c - 'a';
                            else if (c >= 'A' && c <= 'F') code |= 10 + c - 'A';
                            else return false;
                        }
                        p_ += 4;
                        // Encode codepoint as UTF-8. Surrogate pairs
                        // are rare here (Myanmar lives in the BMP),
                        // but handle the high surrogate path so we
                        // don't silently corrupt anything outside.
                        if (code < 0x80) {
                            out += static_cast<char>(code);
                        } else if (code < 0x800) {
                            out += static_cast<char>(0xC0 | (code >> 6));
                            out += static_cast<char>(0x80 | (code & 0x3F));
                        } else if (code >= 0xD800 && code <= 0xDBFF) {
                            // High surrogate; expect \uXXXX low surrogate
                            if (p_ + 6 >= end_ || p_[1] != '\\' || p_[2] != 'u') return false;
                            unsigned int low = 0;
                            for (int i = 3; i <= 6; ++i) {
                                char c = p_[i];
                                low <<= 4;
                                if (c >= '0' && c <= '9') low |= c - '0';
                                else if (c >= 'a' && c <= 'f') low |= 10 + c - 'a';
                                else if (c >= 'A' && c <= 'F') low |= 10 + c - 'A';
                                else return false;
                            }
                            p_ += 6;
                            unsigned int cp = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                            out += static_cast<char>(0xF0 | (cp >> 18));
                            out += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
                            out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
                            out += static_cast<char>(0x80 | (cp & 0x3F));
                        } else {
                            out += static_cast<char>(0xE0 | (code >> 12));
                            out += static_cast<char>(0x80 | ((code >> 6) & 0x3F));
                            out += static_cast<char>(0x80 | (code & 0x3F));
                        }
                        continue;   // p_ already past the escape
                    }
                    default: return false;
                }
                ++p_;
            } else {
                out += *p_;
                ++p_;
            }
        }
        if (p_ >= end_) return false;
        ++p_;   // closing quote
        return true;
    }

    bool parse_int(int& out) noexcept {
        skip_ws();
        bool neg = false;
        if (p_ < end_ && *p_ == '-') { neg = true; ++p_; }
        if (p_ >= end_ || *p_ < '0' || *p_ > '9') return false;
        int v = 0;
        while (p_ < end_ && *p_ >= '0' && *p_ <= '9') {
            v = v * 10 + (*p_ - '0');
            ++p_;
        }
        out = neg ? -v : v;
        return true;
    }

    // Walk past any JSON value without recording it. Used for fields
    // we don't consume (source, score).
    bool skip_value() {
        skip_ws();
        if (p_ >= end_) return false;
        char c = *p_;
        if (c == '"') { std::string ignore; return parse_string(ignore); }
        if (c == '{' || c == '[') {
            const char open  = c;
            const char close = (c == '{') ? '}' : ']';
            ++p_;
            skip_ws();
            if (p_ < end_ && *p_ == close) { ++p_; return true; }
            for (;;) {
                if (open == '{') {
                    std::string key;
                    if (!parse_string(key)) return false;
                    if (!consume(':')) return false;
                }
                if (!skip_value()) return false;
                if (consume(',')) continue;
                if (consume(close)) return true;
                return false;
            }
        }
        // number, true, false, null — read until structural char
        while (p_ < end_) {
            char ch = *p_;
            if (ch == ',' || ch == ']' || ch == '}' || ch == ' '
                || ch == '\t' || ch == '\n' || ch == '\r') break;
            ++p_;
        }
        return true;
    }

    bool parse_candidate(CandidateView& cv) {
        skip_ws();
        if (!consume('{')) return false;
        for (;;) {
            std::string key;
            if (!parse_string(key)) return false;
            if (!consume(':')) return false;
            if (key == "surface") {
                if (!parse_string(cv.surface)) return false;
            } else if (key == "reading") {
                if (!parse_string(cv.reading)) return false;
            } else {
                if (!skip_value()) return false;
            }
            if (consume(',')) continue;
            if (consume('}')) return true;
            return false;
        }
    }

    bool parse_candidates(std::vector<CandidateView>& out) {
        skip_ws();
        if (!consume('[')) return false;
        if (consume(']')) return true;
        for (;;) {
            CandidateView cv;
            if (!parse_candidate(cv)) return false;
            out.push_back(std::move(cv));
            if (consume(',')) continue;
            if (consume(']')) return true;
            return false;
        }
    }

    bool parse_root(ParsedSnapshot& out) {
        skip_ws();
        if (!consume('{')) return false;
        if (consume('}')) return true;
        for (;;) {
            std::string key;
            if (!parse_string(key)) return false;
            if (!consume(':')) return false;
            if (key == "preedit") {
                if (!parse_string(out.preedit)) return false;
            } else if (key == "candidates") {
                if (!parse_candidates(out.candidates)) return false;
            } else if (key == "selected") {
                if (!parse_int(out.selected)) return false;
            } else {
                if (!skip_value()) return false;
            }
            if (consume(',')) continue;
            if (consume('}')) return true;
            return false;
        }
    }

private:
    const char* p_;
    const char* end_;
};

} // namespace

bool parseSnapshot(const std::string& json, ParsedSnapshot& out) noexcept {
    out.preedit.clear();
    out.candidates.clear();
    out.selected = 0;
    try {
        Parser p(json.data(), json.size());
        return p.parse_root(out);
    } catch (...) {
        return false;
    }
}

} // namespace burmese
