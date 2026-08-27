#pragma once
#include <windows.h>
#include <stdio.h>

class PerfTimer {
public:
	static inline LARGE_INTEGER s_freq = {};
	static inline LARGE_INTEGER s_start = {};
	static inline bool s_inited = false;
	static inline bool s_firstFrameLogged = false;

	static void Init() {
		if (!s_inited) {
			QueryPerformanceFrequency(&s_freq);
			QueryPerformanceCounter(&s_start);
			s_inited = true;
			FILE* f = nullptr;
			_wfopen_s(&f, L"C:\\Users\\My_Home\\Desktop\\projects\\MPC-BE\\startup_perf.log", L"w, ccs=UTF-8");
			if (f) {
				fwprintf(f, L"=== Startup Performance Benchmark ===\n");
				fclose(f);
			}
		}
	}

	static double GetMs() {
		if (!s_inited) Init();
		LARGE_INTEGER now;
		QueryPerformanceCounter(&now);
		return (double)(now.QuadPart - s_start.QuadPart) * 1000.0 / (double)s_freq.QuadPart;
	}

	static void Log(const wchar_t* stage) {
		double ms = GetMs();
		FILE* f = nullptr;
		_wfopen_s(&f, L"C:\\Users\\My_Home\\Desktop\\projects\\MPC-BE\\startup_perf.log", L"a, ccs=UTF-8");
		if (f) {
			fwprintf(f, L"[PERF %8.2f ms] %s\n", ms, stage);
			fflush(f);
			fclose(f);
		}
	}

	static void LogFirstFrame(const wchar_t* renderer) {
		if (!s_firstFrameLogged) {
			s_firstFrameLogged = true;
			double ms = GetMs();
			FILE* f = nullptr;
			_wfopen_s(&f, L"C:\\Users\\My_Home\\Desktop\\projects\\MPC-BE\\startup_perf.log", L"a, ccs=UTF-8");
			if (f) {
				fwprintf(f, L"**************************************************\n");
				fwprintf(f, L"[FIRST FRAME PRESENTED: %8.2f ms] Renderer: %s\n", ms, renderer);
				fwprintf(f, L"**************************************************\n");
				fflush(f);
				fclose(f);
			}
		}
	}
};
