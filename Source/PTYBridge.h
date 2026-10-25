#include <sys/types.h>
pid_t ccam_pty_spawn(const char *executable, char *const argv[], char *const envp[], const char *directory, int rows, int cols, int *master);
int ccam_pty_resize(int master, int rows, int cols);
int ccam_exit_code(int status);
