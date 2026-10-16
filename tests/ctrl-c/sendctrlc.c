/* sendctrlc.exe <pid>
 *
 * Attaches to the console of the given process and delivers CTRL+C to everything
 * attached to it -- exactly what pressing Ctrl+C in that terminal does. */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char** argv) {
    if (argc < 2) return 2;

    FreeConsole();
    if (!AttachConsole((DWORD)atoi(argv[1]))) {
        printf("AttachConsole failed %lu\n", GetLastError());
        return 3;
    }
    SetConsoleCtrlHandler(NULL, TRUE);   /* don't let this helper die from its own signal */
    BOOL ok = GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0);
    Sleep(300);
    printf("sent=%d\n", ok);
    return ok ? 0 : 4;
}
