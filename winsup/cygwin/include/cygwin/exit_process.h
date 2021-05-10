#ifndef EXIT_PROCESS_H
#define EXIT_PROCESS_H

/*
 * This file contains functions to terminate a Win32 process, as gently as
 * possible.
 *
 * If appropriate, we will attempt to emulate a console Ctrl event for the
 * process and its (transitive) children. Otherwise we will fall back to
 * terminating the process(es).
 *
 * As we do not want to export this function in the MSYS2 runtime, these
 * functions are marked as file-local.
 *
 * The idea is to inject a thread into the given process that runs either
 * kernel32!CtrlRoutine() (i.e. the work horse of GenerateConsoleCtrlEvent())
 * for SIGINT (Ctrl+C) and SIGQUIT (Ctrl+Break), or ExitProcess() for SIGTERM.
 *
 * For SIGKILL, we run TerminateProcess() without injecting anything, and this
 * is also the fall-back when the previous methods are unavailable.
 *
 * Note: as kernel32.dll is loaded before any process, the other process and
 * this process will have ExitProcess() at the same address. The same holds
 * true for kernel32!CtrlRoutine(), of course, but it is an internal API
 * function, so we cannot look it up directly. Instead, we launch
 * cygwin-console-helper.exe to find out (which has been modified to offer the
 * option to print the address to stdout).
 *
 * This function expects the process handle to have the access rights for
 * CreateRemoteThread(): PROCESS_CREATE_THREAD, PROCESS_QUERY_INFORMATION,
 * PROCESS_VM_OPERATION, PROCESS_VM_WRITE, and PROCESS_VM_READ.
 *
 * The idea for the injected remote thread comes from the Dr Dobb's article "A
 * Safer Alternative to TerminateProcess()" by Andrew Tucker (July 1, 1999),
 * http://www.drdobbs.com/a-safer-alternative-to-terminateprocess/184416547.
 *
 * The idea to use kernel32!CtrlRoutine for the other signals comes from
 * SendSignal (https://github.com/AutoSQA/SendSignal/ and
 * http://stanislavs.org/stopping-command-line-applications-programatically-with-ctrl-c-events-from-net/).
 */

#include <wchar.h>

#ifndef __INSIDE_CYGWIN__
/* To help debugging via kill.exe */
#define small_printf(...) fprintf(stderr, __VA_ARGS__)
#endif

static LPTHREAD_START_ROUTINE
get_address_from_cygwin_console_helper(int bitness, wchar_t *function_name)
{
  const char *name;
  if (bitness == 32)
    name = "/usr/libexec/getprocaddr32.exe";
  else if (bitness == 64)
    name = "/usr/libexec/getprocaddr64.exe";
  else
    return NULL; /* what?!? */
  wchar_t wbuf[PATH_MAX];
  if (cygwin_conv_path (CCP_POSIX_TO_WIN_W, name, wbuf, PATH_MAX) ||
      GetFileAttributesW (wbuf) == INVALID_FILE_ATTRIBUTES)
    return NULL;

  HANDLE h[2];
  SECURITY_ATTRIBUTES attrs;
  attrs.nLength = sizeof(attrs);
  attrs.bInheritHandle = TRUE;
  attrs.lpSecurityDescriptor = NULL;
  if (!CreatePipe(&h[0], &h[1], &attrs, 0))
    return NULL;

  STARTUPINFOW si = {};
  PROCESS_INFORMATION pi;
  size_t len = wcslen (wbuf) + wcslen (function_name) + 1;
  WCHAR cmd[len + 1];
  WCHAR title[] = L"cygwin-console-helper";

  swprintf (cmd, len + 1, L"%S %S", wbuf, function_name);

  si.cb = sizeof (si);
  si.dwFlags = STARTF_USESHOWWINDOW | STARTF_USESTDHANDLES;
  si.wShowWindow = SW_HIDE;
  si.lpTitle = title;
  si.hStdInput = si.hStdError = INVALID_HANDLE_VALUE;
  si.hStdOutput = h[1];

  /* Create a new hidden process.  Use the two event handles as
     argv[1] and argv[2]. */
  BOOL x = CreateProcessW (NULL, cmd, NULL, NULL, TRUE,
			   CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP,
			   NULL, NULL, &si, &pi);
  CloseHandle(h[1]);
  if (!x)
    {
      CloseHandle(h[0]);
      return NULL;
    }

  CloseHandle (pi.hThread);
  CloseHandle (pi.hProcess);

  char buffer[64];
  DWORD offset = 0, count = 0;
  while (offset < sizeof(buffer) - 1)
    {
      if (!ReadFile(h[0], buffer + offset, 1, &count, NULL))
	{
	  offset = 0;
	  break;
	}
      if (!count || buffer[offset] == '\n')
	break;
      offset += count;
    }
  CloseHandle(h[0]);

  buffer[offset] = '\0';

  return (LPTHREAD_START_ROUTINE) strtoull(buffer, NULL, 16);
}

static int current_is_wow = -1;
static int is_32_bit_os = -1;

static BOOL get_wow(HANDLE process, BOOL& is_wow, int& bitness)
{
  if (is_32_bit_os == -1)
    {
      SYSTEM_INFO info;

      GetNativeSystemInfo(&info);
      if (info.wProcessorArchitecture == 0)
	is_32_bit_os = 1;
      else if (info.wProcessorArchitecture == 9)
	is_32_bit_os = 0;
      else
	is_32_bit_os = -2;
    }

  if (current_is_wow == -1 &&
      !IsWow64Process (GetCurrentProcess (), &current_is_wow))
    current_is_wow = -2;

  if (is_32_bit_os == -2 || current_is_wow == -2)
    return FALSE;

  if (!IsWow64Process (process, &is_wow))
    return FALSE;

  bitness = is_32_bit_os || is_wow ? 32 : 64;
  return TRUE;
}

static LPTHREAD_START_ROUTINE
get_exit_process_address_for_process(HANDLE process)
{
  BOOL is_wow;
  int bitness;
  if (!get_wow (process, is_wow, bitness))
    return NULL; /* could not determine */

  if (is_wow == current_is_wow)
    {
      static LPTHREAD_START_ROUTINE exit_process_address;
      if (!exit_process_address)
	{
	  HINSTANCE kernel32 = GetModuleHandle ("kernel32");
	  exit_process_address = (LPTHREAD_START_ROUTINE)
	    GetProcAddress (kernel32, "ExitProcess");
	}
      return exit_process_address;
    }

  /* Trying to terminate a 32-bit process from 64-bit or vice versa */
  static LPTHREAD_START_ROUTINE exit_process_address;
  if (!exit_process_address)
    {
      exit_process_address =
	get_address_from_cygwin_console_helper(bitness, L"ExitProcess");
    }
  return exit_process_address;
}

static LPTHREAD_START_ROUTINE
get_ctrl_routine_address_for_process(HANDLE process)
{
  BOOL is_wow;
  int bitness;
  if (!get_wow (process, is_wow, bitness))
    return NULL; /* could not determine */

  if (bitness == 64)
    {
      static LPTHREAD_START_ROUTINE ctrl_routine_address;
      if (!ctrl_routine_address)
	ctrl_routine_address =
	  get_address_from_cygwin_console_helper(64, L"CtrlRoutine");
      return ctrl_routine_address;
    }

  static LPTHREAD_START_ROUTINE ctrl_routine_address;
  if (!ctrl_routine_address)
    {
      ctrl_routine_address =
	get_address_from_cygwin_console_helper(32, L"CtrlRoutine");
    }
  return ctrl_routine_address;
}

static int
inject_remote_thread_into_process(HANDLE process, LPTHREAD_START_ROUTINE address, int exit_code)
{
  int res = -1;

  if (!address)
    return res;

  DWORD thread_id;
  HANDLE thread = CreateRemoteThread (process, NULL, 1024 * 1024, address,
				      (PVOID) exit_code, 0, &thread_id);
  if (thread)
    {
      /*
      * Wait up to 10 seconds (arbitrary constant) for the thread to finish;
      * After that grace period, fall back to terminating non-gently.
      */
      if (WaitForSingleObject (thread, 10000) == WAIT_OBJECT_0)
          res = 0;
      CloseHandle (thread);
    }

  return res;
}

#define PROCESS_BASIC_INFORMATION_SIZE_32 0x18
#define PEB_OFFSET_32 0x4
#define PARAMS_OFFSET_32 0x10
#define CONSOLE_FLAGS_OFFSET_32 0x14

#define PROCESS_BASIC_INFORMATION_SIZE_64 0x30
#define PEB_OFFSET_64 0x8
#define PARAMS_OFFSET_64 0x20
#define CONSOLE_FLAGS_OFFSET_64 0x18

/**
 * Adjust the ConsoleFlags to allow the process to accept Ctrl+C.
 *
 * The handle must be opened with PROCESS_QUERY_INFORMATION | PROCESS_VM_READ | PROCESS_WRITE.
 *
 * Returns 1 if the ConsoleFlags were cleared, 0 if they had already been cleared, and -1
 * on unspecified error.
 */
static int
adjust_console_flag(HANDLE process)
{
  union
    {
      char chars[PROCESS_BASIC_INFORMATION_SIZE_64];
      ULONG32 ulong32;
      ULONG64 ulong64;
    } u;
  int res = 0;
  char flags;

#ifdef __LP64__
  /* Are we looking at a 32-bit process from a 64-bit one? */
  if (!NtQueryInformationProcess (process, ProcessWow64Information, &u.chars, 8, NULL) && u.ulong64)
    {
      SIZE_T size;
      if (!ReadProcessMemory (process, (char *)u.ulong64 + PARAMS_OFFSET_32, u.chars, 4, &size) || size != 4)
	return -1;
      if (!ReadProcessMemory (process, (char *)(ULONG64)u.ulong32 + CONSOLE_FLAGS_OFFSET_32, &flags, 1, &size) || size != 1)
	return -1;
      if (flags == 1)
        {
	  res = 1;
	  flags = 0;
	  if (!WriteProcessMemory (process, (char *)(ULONG64)u.ulong32 + CONSOLE_FLAGS_OFFSET_32, &flags, 1, &size) || size != 1)
	    return -1;
	}
    }

  if (!NtQueryInformationProcess (process, ProcessBasicInformation, u.chars, PROCESS_BASIC_INFORMATION_SIZE_64, NULL))
   {
     SIZE_T size;
     if (!ReadProcessMemory (process, (char *)*(ULONG64 *)(u.chars + PEB_OFFSET_64) + PARAMS_OFFSET_64, u.chars, 8, &size) || size != 8)
       return -1;
     if (!ReadProcessMemory (process, (char *)u.ulong64 + CONSOLE_FLAGS_OFFSET_64, &flags, 1, &size) || size != 1)
       return -1;
     if (flags == 1)
       {
	 res = 1;
	 flags = 0;
	 if (!WriteProcessMemory (process, (char *)u.ulong64 + CONSOLE_FLAGS_OFFSET_64, &flags, 1, &size) || size != 1)
	   return -1;
       }
   }
#else
  if (!NtQueryInformationProcess(process, ProcessBasicInformation, u.chars, PROCESS_BASIC_INFORMATION_SIZE_32, NULL) && (char *)*(ULONG32 *)(u.chars + PEB_OFFSET_32))
    {
      SIZE_T size;
      if (!ReadProcessMemory (process, (char *)*(ULONG32 *)(u.chars + PEB_OFFSET_32) + PARAMS_OFFSET_32, u.chars, 8, &size) || size != 8)
	return -1;
      if (!ReadProcessMemory (process, (char *)u.ulong32 + CONSOLE_FLAGS_OFFSET_32, &flags, 1, &size) || size != 1)
	return -1;
      if (flags == 1)
        {
	  res = 1;
	  flags = 0;
	  if (!WriteProcessMemory (process, (char *)u.ulong32 + CONSOLE_FLAGS_OFFSET_32, &flags, 1, &size) || size != 1)
	    return -1;
	}
    }

  /* So maybe this is a 32-bit process looking at a 64-bit one? */
  {
    HMODULE ntdll = GetModuleHandleA("ntdll.dll");
    static NTSTATUS(NTAPI *NtWow64ReadVirtualMemory64)(HANDLE process, ULONG64 address, PVOID buffer, ULONG64 size, PULONG64 count);
    static NTSTATUS(NTAPI *NtWow64WriteVirtualMemory64)(HANDLE process, ULONG64 address, PVOID buffer, ULONG64 size, PULONG64 count);
    static NTSTATUS(NTAPI *NtWow64QueryInformationProcess64)(HANDLE process, PROCESSINFOCLASS info_class, PVOID buffer, ULONG size, PULONG count);
    static int initialized;
    ULONG64 size;

    if (!initialized)
      {
	initialized = 1;
	NtWow64ReadVirtualMemory64 = (typeof (NtWow64ReadVirtualMemory64))GetProcAddress (ntdll, "NtWow64ReadVirtualMemory64");
	NtWow64WriteVirtualMemory64 = (typeof (NtWow64WriteVirtualMemory64))GetProcAddress (ntdll, "NtWow64WriteVirtualMemory64");
	NtWow64QueryInformationProcess64 = (typeof (NtWow64QueryInformationProcess64))GetProcAddress (ntdll, "NtWow64QueryInformationProcess64");
      }

    if (NtWow64ReadVirtualMemory64 && NtWow64WriteVirtualMemory64 && NtWow64QueryInformationProcess64)
      if (!NtWow64QueryInformationProcess64 (process, ProcessBasicInformation, u.chars, PROCESS_BASIC_INFORMATION_SIZE_64, NULL))
        {
	  if (NtWow64ReadVirtualMemory64 (process, *(ULONG64 *)(u.chars + PEB_OFFSET_64) + PARAMS_OFFSET_64, u.chars, 8, &size) || size != 8)
	    return -1;
	  if (NtWow64ReadVirtualMemory64(process, u.ulong64 + CONSOLE_FLAGS_OFFSET_64, &flags, 1, &size) || size != 1)
	    return -1;
	}
      if (flags == 1)
        {
	  res = 1;
	  flags = 0;
	  if (NtWow64WriteVirtualMemory64(process, u.ulong64 + CONSOLE_FLAGS_OFFSET_64, &flags, 1, &size) || size != 1)
	    return -1;
	}
  }
#endif
  return res;
}

/**
 * Terminates the process corresponding to the process ID
 *
 * This way of terminating the processes is not gentle: the process gets
 * no chance of cleaning up after itself (closing file handles, removing
 * .lock files, terminating spawned processes (if any), etc).
 */
static int
exit_one_process(HANDLE process, int exit_code)
{
  LPTHREAD_START_ROUTINE address = NULL;
  int signo = exit_code & 0x7f;

TODO: use IsProcessCritical() if available (Windows 8.1 and later) to skip this
  switch (signo)
    {
      case SIGINT:
      case SIGQUIT:
	address = get_ctrl_routine_address_for_process(process);
	if (address &&
	    !inject_remote_thread_into_process(process, address,
					       signo == SIGINT ?
					       CTRL_C_EVENT :
					       CTRL_BREAK_EVENT)) {
	  DWORD code;
	  if (signo == SIGINT && !GetExitCodeProcess (process, &code) ||
	      code == STILL_ACTIVE && adjust_console_flag(process) > 0 &&
	      !inject_remote_thread_into_process(process, address, CTRL_C_EVENT))
	    return 0;
	}
	/* fall-through */
      case SIGTERM:
	address = get_exit_process_address_for_process(process);
	if (address && !inject_remote_thread_into_process(process, address, exit_code))
	  return 0;
	break;
      default:
	break;
    }

  return int(TerminateProcess (process, exit_code));
}

#include <tlhelp32.h>
#include <unistd.h>

/**
 * Terminates the process corresponding to the process ID and all of its
 * directly and indirectly spawned subprocesses using the
 * exit_one_process() function.
 */
static int
exit_process_tree(HANDLE main_process, int exit_code)
{
  HANDLE snapshot = CreateToolhelp32Snapshot (TH32CS_SNAPPROCESS, 0);
  PROCESSENTRY32 entry;
  DWORD pids[16384];
  int max_len = sizeof (pids) / sizeof (*pids), i, len, ret = 0;
  pid_t pid = GetProcessId (main_process);
  int signo = exit_code & 0x7f;

  pids[0] = (DWORD) pid;
  len = 1;

  /*
   * Even if Process32First()/Process32Next() seem to traverse the
   * processes in topological order (i.e. parent processes before
   * child processes), there is nothing in the Win32 API documentation
   * suggesting that this is guaranteed.
   *
   * Therefore, run through them at least twice and stop when no more
   * process IDs were added to the list.
   */
  for (;;)
    {
      memset (&entry, 0, sizeof (entry));
      entry.dwSize = sizeof (entry);

      if (!Process32First (snapshot, &entry))
        break;

      int orig_len = len;
      do
        {
	  /**
	   * Look for the parent process ID in the list of pids to kill, and if
	   * found, add it to the list.
	   */
          for (i = len - 1; i >= 0; i--)
            {
              if (pids[i] == entry.th32ProcessID)
                break;
              if (pids[i] != entry.th32ParentProcessID)
	        continue;

              /* We found a process to kill; is it an MSYS2 process? */
	      pid_t cyg_pid = cygwin_winpid_to_pid(entry.th32ProcessID);
              if (cyg_pid > -1)
                {
                  if (cyg_pid == getpgid (cyg_pid))
                    kill(cyg_pid, signo);
                  break;
                }
	      pids[len++] = entry.th32ProcessID;
	      break;
            }
        }
      while (len < max_len && Process32Next (snapshot, &entry));

      if (orig_len == len || len >= max_len)
        break;
    }

  for (i = len - 1; i >= 0; i--)
    {
      HANDLE process;

      if (!i)
	process = main_process;
      else
        {
	  process = OpenProcess (PROCESS_CREATE_THREAD |
				 PROCESS_QUERY_INFORMATION |
				 PROCESS_VM_OPERATION | PROCESS_VM_WRITE |
				 PROCESS_VM_READ, FALSE, pids[i]);
	  if (!process)
	    process = OpenProcess (PROCESS_TERMINATE, FALSE, pids[i]);
	}
      DWORD code;

      if (process &&
	  (!GetExitCodeProcess (process, &code) || code == STILL_ACTIVE))
        {
          if (!exit_one_process (process, exit_code))
            ret = -1;
        }
      if (process)
        CloseHandle (process);
    }

  return ret;
}

#endif
