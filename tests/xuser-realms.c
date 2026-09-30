#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wininet.h>
#include <stdio.h>
#include <string.h>
#include "XUserRealms.h"

static unsigned int checks, failures;

static void route(const char *name, const char *address, BOOL expected)
{
    URL_COMPONENTSA url = {0};
    const char *audience;
    BOOL ok;
    url.dwStructSize = sizeof(url);
    url.dwHostNameLength = 1;
    url.dwUrlPathLength = 1;
    ok = InternetCrackUrlA(address, 0, 0, &url);
    audience = ok ? xuser_realms_relying_party(&url) : NULL;
    ++checks;
    if (!ok || (!!audience != expected) ||
        (audience && strcmp(audience, "https://pocket.realms.minecraft.net/")))
    {
        ++failures;
        printf("FAIL %s\n", name);
    }
}

void mainCRTStartup(void)
{
    route("legacy-host", "https://pocket.realms.minecraft.net/worlds", TRUE);
    route("frontend-host", "https://bedrock.frontend.realms.minecraft-services.net/worlds", TRUE);
    route("frontendlegacy-host", "https://bedrock.frontendlegacy.realms.minecraft-services.net/worlds", TRUE);
    route("case-insensitive", "https://BEDROCK.FRONTENDLEGACY.REALMS.MINECRAFT-SERVICES.NET/worlds", TRUE);
    route("explicit-https-port", "https://pocket.realms.minecraft.net:443/worlds", TRUE);
    route("http", "http://pocket.realms.minecraft.net/worlds", FALSE);
    route("other-port", "https://pocket.realms.minecraft.net:8443/worlds", FALSE);
    route("unrelated-service", "https://authorization.franchise.minecraft-services.net/", FALSE);
    route("unrelated-xbox", "https://profile.xboxlive.com/", FALSE);
    route("playfab-unchanged", "https://20ca2.playfabapi.com/", FALSE);
    route("subdomain", "https://fake.pocket.realms.minecraft.net/", FALSE);
    route("suffix", "https://pocket.realms.minecraft.net.example.org/", FALSE);
    route("similar-host", "https://notpocket.realms.minecraft.net/", FALSE);
    route("new-host-suffix", "https://bedrock.frontendlegacy.realms.minecraft-services.net.example.org/", FALSE);
    route("host-in-path", "https://example.org/pocket.realms.minecraft.net/", FALSE);
    route("host-in-query", "https://example.org/?host=pocket.realms.minecraft.net", FALSE);
    route("host-in-userinfo", "https://pocket.realms.minecraft.net@example.org/", FALSE);
    route("query-does-not-change-host", "https://pocket.realms.minecraft.net/worlds?host=example.org", TRUE);
    ++checks;
    if (xuser_realms_relying_party(NULL)) ++failures;
    printf("Realms routing: %u checks, %u failures\n", checks, failures);
    ExitProcess(failures ? 1 : 0);
}
