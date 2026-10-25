#include "PTYBridge.h"
#include <util.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <signal.h>

// All strings and argv are allocated by the parent before forkpty. The child
// executes only async-signal-safe system calls, never Swift or Objective-C.
pid_t ccam_pty_spawn(const char *executable, char *const argv[], char *const envp[], const char *directory, int rows, int cols, int *master) {
    struct winsize size = { .ws_row = rows, .ws_col = cols };
    pid_t pid = forkpty(master, NULL, NULL, &size);
    if (pid == 0) {
        if (chdir(directory) != 0) {
            const char message[] = "Unable to enter the project directory.\r\n";
            write(STDERR_FILENO, message, sizeof(message)-1);
            _exit(126);
        }
        struct sigaction action = { .sa_handler = SIG_DFL };
        sigemptyset(&action.sa_mask);
        sigaction(SIGPIPE, &action, NULL);
        sigaction(SIGINT, &action, NULL);
        sigaction(SIGTERM, &action, NULL);
        execve(executable, argv, envp);
        const char message[] = "Unable to start the executable.\r\n";
        write(STDERR_FILENO, message, sizeof(message)-1);
        _exit(127);
    }
    if (pid > 0) {
        fcntl(*master, F_SETFD, FD_CLOEXEC);
        fcntl(*master, F_SETFL, fcntl(*master, F_GETFL) | O_NONBLOCK);
    }
    return pid;
}
int ccam_pty_resize(int master, int rows, int cols) {
    struct winsize size = { .ws_row = rows, .ws_col = cols };
    return ioctl(master, TIOCSWINSZ, &size);
}
int ccam_exit_code(int status) {
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -1;
}
