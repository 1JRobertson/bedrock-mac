/* PlayFab-style caller regression, not a Windows API conformance test.
 * WinHttpWriteData may complete inline on Windows. The bundled SDK advances
 * its send offset after the call returns and needs non-nested completions.
 * All request bodies and the loopback peer are synthetic. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

struct transfer {
    HANDLE sent, written, done, read, closed;
    char body[307];
    DWORD size, supplied, completed, writes, nested, error;
    BOOL in_write, callback_writer;
};

static void fail(struct transfer *t, DWORD error)
{
    t->error = error ? error : ERROR_INVALID_DATA;
    SetEvent(t->sent);
    SetEvent(t->written);
    SetEvent(t->done);
    SetEvent(t->read);
}

static void write_next(HINTERNET request, struct transfer *t)
{
    DWORD length;
    if (t->supplied >= t->size) {
        if (!WinHttpReceiveResponse(request, NULL)) fail(t, GetLastError());
        return;
    }
    length = t->size - t->supplied;
    t->writes++;
    t->in_write = TRUE;
    if (!WinHttpWriteData(request, t->body + t->supplied, length, NULL))
        fail(t, GetLastError());
    /* Deliberately match the SDK's ordering. Recursion resends the same bytes. */
    t->supplied += length;
    t->in_write = FALSE;
}

static void CALLBACK status_callback(HINTERNET request, DWORD_PTR context,
                                    DWORD status, void *info, DWORD length)
{
    struct transfer *t = (struct transfer *)context;
    if (!t) return;
    switch (status) {
    case WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE:
        if (t->callback_writer) write_next(request, t);
        else SetEvent(t->sent);
        break;
    case WINHTTP_CALLBACK_STATUS_WRITE_COMPLETE:
        if (length != sizeof(DWORD)) { fail(t, ERROR_INVALID_DATA); break; }
        t->completed += *(DWORD *)info;
        if (t->in_write) t->nested++;
        if (t->callback_writer) write_next(request, t);
        else SetEvent(t->written);
        break;
    case WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE:
        SetEvent(t->done);
        break;
    case WINHTTP_CALLBACK_STATUS_READ_COMPLETE:
        if (length) fail(t, ERROR_INVALID_DATA);
        SetEvent(t->read);
        break;
    case WINHTTP_CALLBACK_STATUS_REQUEST_ERROR:
        fail(t, ((WINHTTP_ASYNC_RESULT *)info)->dwError);
        break;
    case WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING:
        SetEvent(t->closed);
        break;
    }
}

static BOOL await_event(HANDLE event, struct transfer *t)
{
    if (WaitForSingleObject(event, 10000) != WAIT_OBJECT_0)
        fail(t, ERROR_TIMEOUT);
    return !t->error;
}

static BOOL test_request(HINTERNET connection, unsigned index, unsigned mode)
{
    struct transfer t = {0};
    WCHAR path[8];
    HINTERNET request;
    DWORD status = 0, length = sizeof(status), written = 0;
    BOOL ok = FALSE;
    char response;
    t.size = index == 1 ? 307 : 61;
    t.callback_writer = mode == 2;
    memset(t.body, index == 1 ? 'a' : 'b', t.size);
    t.sent = CreateEventW(NULL, TRUE, FALSE, NULL);
    t.written = CreateEventW(NULL, TRUE, FALSE, NULL);
    t.done = CreateEventW(NULL, TRUE, FALSE, NULL);
    t.read = CreateEventW(NULL, TRUE, FALSE, NULL);
    t.closed = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!t.sent || !t.written || !t.done || !t.read || !t.closed) ExitProcess(2);
    path[0] = '/'; path[1] = '0' + index; path[2] = 0;
    request = WinHttpOpenRequest(connection, L"POST", path, NULL, NULL, NULL, 0);
    if (!request) goto cleanup;
    if (mode) {
        if (WinHttpSetStatusCallback(request, status_callback,
                WINHTTP_CALLBACK_FLAG_ALL_NOTIFICATIONS, 0) == WINHTTP_INVALID_STATUS_CALLBACK)
            goto cleanup;
    }
    if (!WinHttpSendRequest(request, NULL, 0, NULL, 0, t.size, (DWORD_PTR)&t))
        goto cleanup;
    if (mode == 2) {
        if (!await_event(t.done, &t)) goto cleanup;
    } else {
        if (mode && !await_event(t.sent, &t)) goto cleanup;
        if (!WinHttpWriteData(request, t.body, t.size, mode ? NULL : &written))
            goto cleanup;
        if (mode && !await_event(t.written, &t)) goto cleanup;
        if (!mode && written != t.size) goto cleanup;
        if (!WinHttpReceiveResponse(request, NULL)) goto cleanup;
        if (mode && !await_event(t.done, &t)) goto cleanup;
    }
    if (!WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                             NULL, &status, &length, NULL) || status != 200)
        goto cleanup;
    /* The loopback response has Content-Length: 0, allowing connection reuse. */
    if (!WinHttpReadData(request, &response, 1, mode ? NULL : &written)) goto cleanup;
    if (mode && !await_event(t.read, &t)) goto cleanup;
    if (!mode && written) goto cleanup;
    ok = mode != 2 || (t.writes == 1 && t.supplied == t.size &&
                       t.completed == t.size && !t.nested);
cleanup:
    if (request) {
        WinHttpCloseHandle(request);
        if (mode && WaitForSingleObject(t.closed, 10000) != WAIT_OBJECT_0)
            ExitProcess(2); /* Do not free callback state that might still be used. */
    }
    printf("request=%u mode=%u status=%lu writes=%lu supplied=%lu completed=%lu nested=%lu error=%lu ok=%u\n",
           index, mode, status, t.writes, t.supplied, t.completed, t.nested, t.error, ok);
    CloseHandle(t.sent); CloseHandle(t.written); CloseHandle(t.done);
    CloseHandle(t.read); CloseHandle(t.closed);
    return ok;
}

void mainCRTStartup(void)
{
    WCHAR command[1024], *argument;
    HINTERNET session, connection;
    unsigned mode, port;
    BOOL ok;
    /* This small PE uses a direct entry point, without CRT argument startup. */
    if (lstrlenW(GetCommandLineW()) >= 1024) ExitProcess(2);
    lstrcpyW(command, GetCommandLineW());
    if (!(argument = wcsrchr(command, ' '))) ExitProcess(2);
    mode = wcstoul(argument + 1, NULL, 10);
    *argument = 0;
    if (!(argument = wcsrchr(command, ' '))) ExitProcess(2);
    port = wcstoul(argument + 1, NULL, 10);
    if (!port || port > 65535 || mode > 2) ExitProcess(2);
    session = WinHttpOpen(L"synthetic-write-regression", WINHTTP_ACCESS_TYPE_NO_PROXY,
                         NULL, NULL, mode ? WINHTTP_FLAG_ASYNC : 0);
    if (!session) ExitProcess(2);
    WinHttpSetTimeouts(session, 5000, 5000, 5000, 5000);
    connection = WinHttpConnect(session, L"127.0.0.1", port, 0);
    if (!connection) ExitProcess(2);
    ok = test_request(connection, 1, mode);
    if (!test_request(connection, 2, mode)) ok = FALSE;
    WinHttpCloseHandle(connection);
    WinHttpCloseHandle(session);
    ExitProcess(ok ? 0 : 1);
}
