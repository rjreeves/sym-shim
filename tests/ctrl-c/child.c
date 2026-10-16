/* Test program that sits behind the shim.
 *   CTRLC_MODE=handle  -> handles Ctrl+C itself and carries on, like a shell or REPL.
 *   CTRLC_MODE=default -> default Ctrl+C handling (dies).
 * Runs about 6 seconds, logging to CTRLC_LOG, then exits with code 7. */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static FILE* lg;

static BOOL WINAPI on_ctrl(DWORD type) {
    if (type == CTRL_C_EVENT) {
        fprintf(lg, "child: ctrl-c received (handled, carrying on)\n");
        fflush(lg);
        return TRUE;
    }
    return FALSE;
}

int main(void) {
    const char* path = getenv("CTRLC_LOG");
    const char* mode = getenv("CTRLC_MODE");
    if (!mode) mode = "default";
    lg = fopen(path ? path : "child.log", "a");
    fprintf(lg, "child: start pid=%lu mode=%s\n", GetCurrentProcessId(), mode);
    fflush(lg);

    if (strcmp(mode, "handle") == 0) SetConsoleCtrlHandler(on_ctrl, TRUE);

    for (int i = 0; i < 30; i++) Sleep(200);

    fprintf(lg, "child: finished normally, exiting 7\n");
    fflush(lg);
    return 7;
}
