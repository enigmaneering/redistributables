// Minimal ATL CComPtr compatibility for MinGW builds
// This provides just enough ATL functionality to compile DXC's MSFileSystemBasic.cpp

#ifndef _ATLBASE_COMPAT_H_
#define _ATLBASE_COMPAT_H_

#include <unknwn.h>
#include <cstdio>
#include <cstdarg>

// ATL macros that DXC expects
#ifndef ATL_NO_VTABLE
#define ATL_NO_VTABLE
#endif

#ifndef _ATL_DECLSPEC_ALLOCATOR
#define _ATL_DECLSPEC_ALLOCATOR
#endif

// MinGW doesn't have OutputDebugFormatA - provide a simple implementation
inline void OutputDebugFormatA(const char* format, ...) {
    char buffer[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    // In MinGW, we can use OutputDebugStringA or just write to stderr
    #ifdef OutputDebugStringA
    OutputDebugStringA(buffer);
    #else
    fprintf(stderr, "%s", buffer);
    #endif
}

// Minimal CComPtr implementation compatible with ATL usage in DXC
template <class T>
class CComPtr {
public:
    T* p;

    CComPtr() : p(nullptr) {}

    CComPtr(T* lp) : p(lp) {
        if (p) p->AddRef();
    }

    CComPtr(const CComPtr& lp) : p(lp.p) {
        if (p) p->AddRef();
    }

    ~CComPtr() {
        if (p) p->Release();
    }

    T* operator->() const {
        return p;
    }

    operator T*() const {
        return p;
    }

    T** operator&() {
        return &p;
    }

    CComPtr& operator=(T* lp) {
        if (p) p->Release();
        p = lp;
        if (p) p->AddRef();
        return *this;
    }

    CComPtr& operator=(const CComPtr& lp) {
        if (p) p->Release();
        p = lp.p;
        if (p) p->AddRef();
        return *this;
    }

    void Release() {
        if (p) {
            p->Release();
            p = nullptr;
        }
    }

    T* Detach() {
        T* pt = p;
        p = nullptr;
        return pt;
    }

    void Attach(T* p2) {
        if (p) p->Release();
        p = p2;
    }

    // ATL-style QueryInterface that takes a pointer to a CComPtr
    // Usage: storage.QueryInterface(&stream) where stream is CComPtr<IStream>
    template <class Q>
    HRESULT QueryInterface(Q** pp) {
        return p ? p->QueryInterface(__uuidof(Q), (void**)pp) : E_POINTER;
    }
};

// Undefine Windows macros that conflict with DXC's COFF.h enum definitions
// winnt.h defines these as macros, but DXC's COFF.h needs them as enum values
#ifdef IMAGE_FILE_MACHINE_UNKNOWN
// Machine types
#undef IMAGE_FILE_MACHINE_UNKNOWN
#undef IMAGE_FILE_MACHINE_AM33
#undef IMAGE_FILE_MACHINE_AMD64
#undef IMAGE_FILE_MACHINE_ARM
#undef IMAGE_FILE_MACHINE_ARMNT
#undef IMAGE_FILE_MACHINE_ARM64
#undef IMAGE_FILE_MACHINE_EBC
#undef IMAGE_FILE_MACHINE_I386
#undef IMAGE_FILE_MACHINE_IA64
#undef IMAGE_FILE_MACHINE_M32R
#undef IMAGE_FILE_MACHINE_MIPS16
#undef IMAGE_FILE_MACHINE_MIPSFPU
#undef IMAGE_FILE_MACHINE_MIPSFPU16
#undef IMAGE_FILE_MACHINE_POWERPC
#undef IMAGE_FILE_MACHINE_POWERPCFP
#undef IMAGE_FILE_MACHINE_R4000
#undef IMAGE_FILE_MACHINE_SH3
#undef IMAGE_FILE_MACHINE_SH3DSP
#undef IMAGE_FILE_MACHINE_SH4
#undef IMAGE_FILE_MACHINE_SH5
#undef IMAGE_FILE_MACHINE_THUMB
#undef IMAGE_FILE_MACHINE_WCEMIPSV2
// File characteristics
#undef IMAGE_FILE_RELOCS_STRIPPED
#undef IMAGE_FILE_EXECUTABLE_IMAGE
#undef IMAGE_FILE_LINE_NUMS_STRIPPED
#undef IMAGE_FILE_LOCAL_SYMS_STRIPPED
#undef IMAGE_FILE_LARGE_ADDRESS_AWARE
#undef IMAGE_FILE_BYTES_REVERSED_LO
#undef IMAGE_FILE_32BIT_MACHINE
#undef IMAGE_FILE_DEBUG_STRIPPED
#undef IMAGE_FILE_REMOVABLE_RUN_FROM_SWAP
#undef IMAGE_FILE_NET_RUN_FROM_SWAP
#undef IMAGE_FILE_SYSTEM
#undef IMAGE_FILE_DLL
#undef IMAGE_FILE_UP_SYSTEM_ONLY
#undef IMAGE_FILE_BYTES_REVERSED_HI
// Symbol values
#undef IMAGE_SYM_DEBUG
#undef IMAGE_SYM_ABSOLUTE
#undef IMAGE_SYM_UNDEFINED
// Symbol storage class - all IMAGE_SYM_CLASS_* macros
#undef IMAGE_SYM_CLASS_END_OF_FUNCTION
#undef IMAGE_SYM_CLASS_NULL
#undef IMAGE_SYM_CLASS_AUTOMATIC
#undef IMAGE_SYM_CLASS_EXTERNAL
#undef IMAGE_SYM_CLASS_STATIC
#undef IMAGE_SYM_CLASS_REGISTER
#undef IMAGE_SYM_CLASS_EXTERNAL_DEF
#undef IMAGE_SYM_CLASS_LABEL
#undef IMAGE_SYM_CLASS_UNDEFINED_LABEL
#undef IMAGE_SYM_CLASS_MEMBER_OF_STRUCT
#undef IMAGE_SYM_CLASS_ARGUMENT
#undef IMAGE_SYM_CLASS_STRUCT_TAG
#undef IMAGE_SYM_CLASS_MEMBER_OF_UNION
#undef IMAGE_SYM_CLASS_UNION_TAG
#undef IMAGE_SYM_CLASS_TYPE_DEFINITION
#undef IMAGE_SYM_CLASS_UNDEFINED_STATIC
#undef IMAGE_SYM_CLASS_ENUM_TAG
#undef IMAGE_SYM_CLASS_MEMBER_OF_ENUM
#undef IMAGE_SYM_CLASS_REGISTER_PARAM
#undef IMAGE_SYM_CLASS_BIT_FIELD
#undef IMAGE_SYM_CLASS_BLOCK
#undef IMAGE_SYM_CLASS_FUNCTION
#undef IMAGE_SYM_CLASS_END_OF_STRUCT
#undef IMAGE_SYM_CLASS_FILE
#undef IMAGE_SYM_CLASS_SECTION
#undef IMAGE_SYM_CLASS_WEAK_EXTERNAL
#undef IMAGE_SYM_CLASS_CLR_TOKEN
#endif

#endif // _ATLBASE_COMPAT_H_
