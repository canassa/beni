// icount <cmd> [args…]: the user-space instructions <cmd> and every thread
// and process it makes retire, printed to stderr.
#include <linux/perf_event.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
  struct perf_event_attr a;
  memset(&a, 0, sizeof a);
  a.size = sizeof a;
  a.type = PERF_TYPE_HARDWARE;
  a.config = PERF_COUNT_HW_INSTRUCTIONS;
  a.inherit = 1;
  a.exclude_kernel = 1;
  a.exclude_hv = 1;
  int fd = syscall(SYS_perf_event_open, &a, 0, -1, -1, 0);
  if (fd < 0) { perror("perf_event_open"); return 2; }
  pid_t p = fork();
  if (p == 0) { execv(argv[1], argv + 1); perror("execv"); _exit(127); }
  int st;
  waitpid(p, &st, 0);
  uint64_t v = 0;
  read(fd, &v, sizeof v);
  fprintf(stderr, "instructions %llu\n", (unsigned long long)v);
  return WIFEXITED(st) ? WEXITSTATUS(st) : 1;
}
