// vg_opaque_ir (5d): LLVM IR text with typed pointers -> the same IR with opaque pointers.
//
// The guest's LLVM (GPUCompiler's, in the dyld cache) prints AIR with typed pointers -- `float addrspace(1)*`,
// `%struct.Seg*`, `i8**` -- while NV's translator was written against opaque ones (`ptr addrspace(1)`), and several
// of its text passes only match those: function constants weren't folded, constexpr samplers behind a bitcast were
// missed, and a device pointer carried around a loop (RenderBox's path coverage: a binary search moving a pointer)
// came out as a null private variable, so the Dock's icon shadow and Spotlight's icons drew nothing. LLVM 23 reading
// the same bitcode prints opaque pointers, and the translator gets that kernel right.
//
// Every pointer type becomes `ptr` (`ptr addrspace(N)`); everything else is left as it is: GEPs, loads and stores
// already name their element types, and a bitcast between two pointers becomes a no-op bitcast from ptr to ptr.
// Text inside quotes and comments is not touched. Header-only C so a host test can use it (tools/opaqueir.c).
#ifndef VG_OPAQUE_IR_H
#define VG_OPAQUE_IR_H
#include <stdlib.h>
#include <string.h>

static int vgo_ident(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '.' ||
           c == '$' || c == '%' || c == '-' || c == '@';
}

// The start of the type that ends at out[end - 1] (spaces before `end` already skipped), or -1.
static long vgo_type_start(const char *out, long end) {
    long p = end - 1;
    if (p < 0) {
        return -1;
    }
    // a pointer already converted: `ptr` or `ptr addrspace(N)`
    if (out[p] == ')') {
        long q = p - 1;
        while (q >= 0 && out[q] >= '0' && out[q] <= '9') {   // `addrspace(<digits>)` only
            q--;
        }
        if (q >= 9 && q < p - 1 && out[q] == '(' && !strncmp(out + q - 9, "addrspace", 9)) {
            long r = q - 9;
            while (r > 0 && out[r - 1] == ' ') {
                r--;
            }
            if (r >= 3 && !strncmp(out + r - 3, "ptr", 3) && (r == 3 || !vgo_ident(out[r - 4]))) {
                return r - 3;
            }
        }
    }
    char c = out[p];
    if (c == ')' ) {   // a function type: RET (ARGS)
        int depth = 0;
        for (; p >= 0; p--) {
            if (out[p] == ')' || out[p] == ']' || out[p] == '}' || out[p] == '>') {
                depth++;
            } else if (out[p] == '(' || out[p] == '[' || out[p] == '{' || out[p] == '<') {
                if (--depth == 0) {
                    break;
                }
            }
        }
        if (p < 0) {
            return -1;
        }
        long q = p;
        while (q > 0 && out[q - 1] == ' ') {
            q--;
        }
        return vgo_type_start(out, q);   // the return type
    }
    if (c == '>' || c == ']' || c == '}') {
        int depth = 0;
        for (; p >= 0; p--) {
            char d = out[p];
            if (d == ')' || d == ']' || d == '}' || d == '>') {
                depth++;
            } else if (d == '(' || d == '[' || d == '{' || d == '<') {
                if (--depth == 0) {
                    break;
                }
            }
        }
        return p;   // `<{ ... }>` ends on '<' too
    }
    if (c == '"') {   // %"quoted name"
        p--;
        while (p >= 0 && out[p] != '"') {
            p--;
        }
        if (p > 0 && out[p - 1] == '%') {
            return p - 1;
        }
        return -1;
    }
    while (p >= 0 && vgo_ident(out[p])) {
        p--;
    }
    return p + 1 < end ? p + 1 : -1;
}

// Returns a malloc'd string (the caller frees it), or NULL when the text has no typed pointers.
static char *vg_opaque_ir(const char *in) {
    size_t n = strlen(in);
    if (!memchr(in, '*', n)) {
        return NULL;
    }
    size_t cap = n + 64;
    char *out = malloc(cap);
    if (!out) {
        return NULL;
    }
    size_t o = 0;
    int inStr = 0, inComment = 0, changed = 0;
    for (size_t i = 0; i < n; i++) {
        char c = in[i];
        if (inComment) {
            if (c == '\n') {
                inComment = 0;
            }
        } else if (inStr) {
            if (c == '"') {
                inStr = 0;
            }
        } else if (c == '"') {
            inStr = 1;
        } else if (c == ';') {
            inComment = 1;
        } else if (c == '*') {
            // this pointer's own address space: written in the input right before the '*'
            long e = (long)o;
            while (e > 0 && out[e - 1] == ' ') {
                e--;
            }
            char as[32] = "";
            long ip = (long)i - 1;
            while (ip >= 0 && in[ip] == ' ') {
                ip--;
            }
            if (ip >= 0 && in[ip] == ')') {
                long q = ip - 1;
                while (q >= 0 && in[q] >= '0' && in[q] <= '9') {   // `addrspace(<digits>)` only
                    q--;
                }
                if (q >= 9 && in[q] == '(' && !strncmp(in + q - 9, "addrspace", 9) && ip - q - 1 > 0 && ip - q - 1 < 16) {
                    memcpy(as, in + q + 1, (size_t)(ip - q - 1));
                    as[ip - q - 1] = 0;
                    // drop " addrspace(N)" from the output too
                    long oq = e - 1;
                    while (oq >= 0 && out[oq] != '(') {
                        oq--;
                    }
                    e = oq - 9;
                    while (e > 0 && out[e - 1] == ' ') {
                        e--;
                    }
                }
            }
            long s = vgo_type_start(out, e);
            if (s >= 0) {
                o = (size_t)s;
                const char *rep = "ptr";
                size_t need = o + 32;
                if (need >= cap) {
                    cap = cap * 2 + 64;
                    out = realloc(out, cap);
                }
                memcpy(out + o, rep, 3);
                o += 3;
                if (as[0] && strcmp(as, "0")) {
                    o += (size_t)sprintf(out + o, " addrspace(%s)", as);
                }
                changed = 1;
                continue;
            }
        }
        if (o + 2 >= cap) {
            cap = cap * 2 + 64;
            out = realloc(out, cap);
        }
        out[o++] = c;
    }
    out[o] = 0;
    if (!changed) {
        free(out);
        return NULL;
    }
    return out;
}
#endif
