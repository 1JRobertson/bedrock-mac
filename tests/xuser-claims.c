#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#ifndef ARRAY_SIZE
#define ARRAY_SIZE(x) (sizeof(x)/sizeof((x)[0]))
#endif
#include "XUserClaims.h"
static unsigned int checks, failures;
static void check(const char *name, BOOL ok) { checks++; if(!ok) { failures++; printf("FAIL %s\n",name); } }
static void claim(const char *name,const WCHAR *s,UINT32 id,BOOL valid,BOOL granted) {
    BOOLEAN allowed=TRUE;
    BOOL actual=xuser_parse_privilege_claim(s,s ? lstrlenW(s) : 0,id,&allowed);
    check(name,actual==valid && allowed==granted);
}
void mainCRTStartup(void) {
    BOOLEAN allowed;
    ULONGLONG base,fraction,value;
    const WCHAR embedded[]={ '2','5','4',0,' ','1','8','5' };
    claim("grant",L"185 254 247",254,TRUE,TRUE);
    claim("deny",L"185 247",254,TRUE,FALSE);
    claim("exact-ID",L"1254 2540",254,TRUE,FALSE);
    claim("explicit-empty-denial",L"",254,TRUE,FALSE);
    claim("whitespace",L" 185\t254\r\n",254,TRUE,TRUE);
    claim("duplicate",L"254 254",254,TRUE,TRUE);
    claim("numeric-leading-zero",L"0254",254,TRUE,TRUE);
    claim("max-integer",L"4294967295 254",254,TRUE,TRUE);
    claim("missing",NULL,254,FALSE,FALSE);
    claim("valid-prefix-malformed-tail",L"254 nope",254,FALSE,FALSE);
    claim("comma",L"254,185",254,FALSE,FALSE);
    claim("negative",L"-254",254,FALSE,FALSE);
    claim("plus",L"+254",254,FALSE,FALSE);
    claim("overflow",L"4294967296 254",254,FALSE,FALSE);
    check("embedded-null",!xuser_parse_privilege_claim(embedded,ARRAY_SIZE(embedded),254,&allowed) && !allowed);
    check("unknown-policy",FAILED(xuser_check_privilege_claim(FALSE,L"254",3,200,100,254,&allowed)) && !allowed);
    check("expired-policy",FAILED(xuser_check_privilege_claim(TRUE,L"254",3,99,100,254,&allowed)) && !allowed);
    check("expiry-boundary",FAILED(xuser_check_privilege_claim(TRUE,L"254",3,100,100,254,&allowed)) && !allowed);
    check("future-policy",xuser_check_privilege_claim(TRUE,L"254",3,101,100,254,&allowed)==S_OK && allowed);
    check("real-denial",xuser_check_privilege_claim(TRUE,L"185",3,101,100,254,&allowed)==S_OK && !allowed);
    check("malformed-policy",FAILED(xuser_check_privilege_claim(TRUE,L"254 x",5,101,100,254,&allowed)) && !allowed);
    check("ISO-UTC",xuser_parse_claim_expiry(L"2026-09-30T03:02:01Z",20,&base));
    check("ISO-fraction",xuser_parse_claim_expiry(L"2026-09-30T03:02:01.1234567Z",28,&fraction) && fraction==base+1234567);
    check("leap-year",xuser_parse_claim_expiry(L"2024-02-29T00:00:00Z",20,&value));
    check("invalid-calendar-day",!xuser_parse_claim_expiry(L"2025-02-29T00:00:00Z",20,&value));
    check("invalid-month",!xuser_parse_claim_expiry(L"2026-13-01T00:00:00Z",20,&value));
    check("invalid-hour",!xuser_parse_claim_expiry(L"2026-01-01T24:00:00Z",20,&value));
    check("missing-expiry",!xuser_parse_claim_expiry(NULL,0,&value));
    check("bad-expiry-suffix",!xuser_parse_claim_expiry(L"2026-09-30T03:02:01X",20,&value));
    check("empty-fraction",!xuser_parse_claim_expiry(L"2026-09-30T03:02:01.Z",21,&value));
    check("too-precise",!xuser_parse_claim_expiry(L"2026-09-30T03:02:01.12345678Z",29,&value));
    printf("Privilege parser: %u checks, %u failures\n",checks,failures);
    ExitProcess(failures?1:0);
}
