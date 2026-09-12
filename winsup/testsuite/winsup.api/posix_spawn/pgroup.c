#include "test.h"
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static void
terminate_child (pid_t pid)
{
  int status;

  kill (pid, SIGKILL);
  waitpid (pid, &status, 0);
}

int
main (int argc, char **argv)
{
  posix_spawnattr_t sa;
  pid_t pid;
  int status;
  char *childargv[] = {"pgroup", "--child", NULL};

  setvbuf (stdout, NULL, _IONBF, 0);

  if (argc == 2 && !strcmp (argv[1], "--child"))
    {
      pause ();
      return 0;
    }

  errCode (posix_spawnattr_init (&sa));
  errCode (posix_spawnattr_setpgroup (&sa, 0));
  errCode (posix_spawnattr_setflags (&sa, POSIX_SPAWN_SETPGROUP));
  errCode (posix_spawn (&pid, MYSELF, NULL, &sa, childargv, environ));
  errCode (posix_spawnattr_destroy (&sa));

  pid_t pgid = getpgid (pid);
  if (pgid != pid)
    {
      int err = errno;
      terminate_child (pid);
      error_at_line (1, err, __FILE__, __LINE__ - 5,
		     "getpgid (%d) returned %d", pid, pgid);
    }

  if (kill (-pid, 0))
    {
      int err = errno;
      terminate_child (pid);
      error_at_line (1, err, __FILE__, __LINE__ - 5,
		     "kill (-%d, 0)", pid);
    }

  if (kill (-pid, SIGTERM))
    {
      int err = errno;
      terminate_child (pid);
      error_at_line (1, err, __FILE__, __LINE__ - 5,
		     "kill (-%d, SIGTERM)", pid);
    }

  negError (waitpid (pid, &status, 0));
  testAssertMsg (WIFSIGNALED (status), "child was not terminated by signal");
  testAssertMsg (WTERMSIG (status) == SIGTERM,
		 "child terminated with signal %d", WTERMSIG (status));

  return 0;
}
