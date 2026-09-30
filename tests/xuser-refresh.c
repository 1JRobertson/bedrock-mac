#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include "XUserRefresh.h"

static unsigned checks, failures;
static void check(const char *name, BOOL pass)
{
    ++checks;
    if (!pass) { ++failures; printf("FAIL %s\n", name); }
}

void mainCRTStartup(void)
{
    const ULONGLONG now = 100000000000ULL;
    const ULONGLONG future = now + XUSER_REFRESH_MARGIN + 1;
    const char *xbox = "http://xboxlive.com";
    const char *realms = "https://pocket.realms.minecraft.net/";
    check("missing-expiry", xuser_expiry_needs_refresh(0, now));
    check("expired", xuser_expiry_needs_refresh(now - 1, now));
    check("exact-expiry", xuser_expiry_needs_refresh(now, now));
    check("just-unexpired", xuser_expiry_needs_refresh(now + 1, now));
    check("margin-boundary", xuser_expiry_needs_refresh(now + XUSER_REFRESH_MARGIN, now));
    check("outside-margin", !xuser_expiry_needs_refresh(future, now));
    check("no-subtraction-wrap", xuser_expiry_needs_refresh(1, ~(ULONGLONG)0));
    check("no-addition-wrap", !xuser_expiry_needs_refresh(~(ULONGLONG)0, now));
    check("normal-cache-hit", !xuser_token_needs_refresh(TRUE, xbox, xbox, future, now, FALSE));
    check("force-refresh-cache-hit", xuser_token_needs_refresh(TRUE, xbox, xbox, future, now, TRUE));
    check("missing-token", xuser_token_needs_refresh(FALSE, xbox, xbox, future, now, FALSE));
    check("missing-audience", xuser_token_needs_refresh(TRUE, NULL, xbox, future, now, FALSE));
    check("different-audience", xuser_token_needs_refresh(TRUE, xbox, realms, future, now, FALSE));
    check("realms-cache-hit", !xuser_token_needs_refresh(TRUE, realms, realms, future, now, FALSE));
    check("expired-same-audience", xuser_token_needs_refresh(TRUE, realms, realms, now - 1, now, FALSE));
    check("unknown-expiry-same-audience", xuser_token_needs_refresh(TRUE, xbox, xbox, 0, now, FALSE));
    check("proactive-same-audience", xuser_token_needs_refresh(TRUE, xbox, xbox, now + XUSER_REFRESH_MARGIN, now, FALSE));
    check("force-different-audience", xuser_token_needs_refresh(TRUE, xbox, realms, future, now, TRUE));
    printf("Token refresh rules: %u checks, %u failures\n", checks, failures);
    ExitProcess(failures ? 1 : 0);
}
