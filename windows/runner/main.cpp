#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

#include <string>

namespace {

// Einzelinstanz (Test win11-1: zwei Fenster gleichzeitig, das aeltere meldete
// "Verbindung unterbrochen"). Ein zweiter Start bringt das vorhandene Fenster
// nach vorn und endet. "Local\" = je Windows-Sitzung: an einem Terminal-
// server hat jede Person ihre eigene Instanz.
constexpr wchar_t kInstanzName[] = L"Local\\ch.rosenweg4303.vm";
constexpr wchar_t kFensterKlasse[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

std::wstring ExePfad(DWORD pid) {
  std::wstring pfad(MAX_PATH * 4, L'\0');
  HANDLE p = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (p == nullptr) return L"";
  DWORD laenge = static_cast<DWORD>(pfad.size());
  BOOL ok = ::QueryFullProcessImageNameW(p, 0, pfad.data(), &laenge);
  ::CloseHandle(p);
  if (!ok) return L"";
  pfad.resize(laenge);
  return pfad;
}

// Fenster derselben .exe (andere Flutter-Apps haben dieselbe Fensterklasse).
BOOL CALLBACK FensterSuchen(HWND hwnd, LPARAM ergebnis) {
  wchar_t klasse[64];
  if (::GetClassNameW(hwnd, klasse, 64) == 0 || wcscmp(klasse, kFensterKlasse) != 0) return TRUE;
  DWORD pid = 0;
  ::GetWindowThreadProcessId(hwnd, &pid);
  if (pid == ::GetCurrentProcessId()) return TRUE;
  if (_wcsicmp(ExePfad(pid).c_str(), ExePfad(::GetCurrentProcessId()).c_str()) != 0) return TRUE;
  *reinterpret_cast<HWND*>(ergebnis) = hwnd;
  return FALSE;
}

void VorhandenesFensterZeigen() {
  HWND hwnd = nullptr;
  // Das erste Fenster erscheint erst mit dem ersten Bild: kurz warten.
  for (int i = 0; i < 20 && hwnd == nullptr; ++i) {
    ::EnumWindows(FensterSuchen, reinterpret_cast<LPARAM>(&hwnd));
    if (hwnd == nullptr) ::Sleep(100);
  }
  if (hwnd == nullptr) return;
  if (::IsIconic(hwnd)) ::ShowWindow(hwnd, SW_RESTORE);
  ::SetForegroundWindow(hwnd);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  HANDLE instanz = ::CreateMutexW(nullptr, TRUE, kInstanzName);
  if (instanz != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    VorhandenesFensterZeigen();
    ::CloseHandle(instanz);
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Rosenweg Virtuelle Computer", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (instanz != nullptr) ::CloseHandle(instanz);
  return EXIT_SUCCESS;
}
