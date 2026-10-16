/* launch.exe <cwd> <cmdline> <exitcode-file>
 *
 * Starts a process in its OWN new, hidden console (so a test can send that console
 * a Ctrl+C without disturbing anything else), prints the new process's pid, then
 * waits for it and records its exit code in <exitcode-file>. */
#include <windows.h>
#include <stdio.h>

int main(int argc, char** argv) {
    if (argc < 4) return 2;

    STARTUPINFOA si = {0};
    PROCESS_INFORMATION pi = {0};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;

    char cmd[4096];
    snprintf(cmd, sizeof cmd, "%s", argv[2]);
    if (!CreateProcessA(NULL, cmd, NULL, NULL, FALSE, CREATE_NEW_CONSOLE, NULL, argv[1], &si, &pi)) {
        printf("CreateProcess failed %lu\n", GetLastError());
        return 3;
    }
    printf("%lu\n", pi.dwProcessId);
    fflush(stdout);

    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    FILE* f = fopen(argv[3], "w");
    if (f) { fprintf(f, "%lu\n", code); fclose(f); }
    return 0;
}
