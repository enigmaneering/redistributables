// Minimal ATL CComPtr compatibility for MinGW builds
// This provides just enough ATL functionality to compile DXC's MSFileSystemBasic.cpp

#ifndef _ATLBASE_COMPAT_H_
#define _ATLBASE_COMPAT_H_

#include <unknwn.h>

// ATL macros that DXC expects
#ifndef ATL_NO_VTABLE
#define ATL_NO_VTABLE
#endif

#ifndef _ATL_DECLSPEC_ALLOCATOR
#define _ATL_DECLSPEC_ALLOCATOR
#endif

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

    HRESULT QueryInterface(REFIID riid, void** ppv) {
        return p ? p->QueryInterface(riid, ppv) : E_POINTER;
    }
};

#endif // _ATLBASE_COMPAT_H_
