#pragma once

#include <windows.h>
#include <stdio.h>
#include <mutex>
#include <vector>

// Opt-in startup tracing. Keep disk I/O and formatting off the startup and
// streaming threads; write the bounded in-memory trace on normal shutdown.
// MPCBE_STARTUP_TRACE is the output filename (unset means no tracing).
class PerfTimer {
	struct Record {
		double ms;
		const wchar_t* kind;
		wchar_t stage[192];
	};

	struct State {
		LARGE_INTEGER freq = {};
		LARGE_INTEGER start = {};
		wchar_t path[MAX_PATH] = {};
		bool enabled = false;
		bool firstSampleLogged = false;
		bool firstFrameLogged = false;
		bool flushed = false;
		std::mutex mutex;
		std::vector<Record> records;

		State() {
			QueryPerformanceFrequency(&freq);
			QueryPerformanceCounter(&start);
			const DWORD length = GetEnvironmentVariableW(L"MPCBE_STARTUP_TRACE", path, MAX_PATH);
			enabled = length > 0 && length < MAX_PATH;
			if (enabled) {
				records.reserve(512);
			}
		}
	};

	static State& GetState() {
		static State state; // C++ also protects concurrent first use.
		return state;
	}

	static void Add(const wchar_t* stage, const wchar_t* kind, bool* once = nullptr) {
		auto& state = GetState();
		if (!state.enabled) {
			return;
		}
		std::lock_guard<std::mutex> lock(state.mutex);
		if (state.flushed || state.records.size() == 512 || (once && *once)) {
			return;
		}
		if (once) {
			*once = true;
		}
		LARGE_INTEGER now;
		QueryPerformanceCounter(&now);
		Record record;
		record.ms = double(now.QuadPart - state.start.QuadPart) * 1000.0 / state.freq.QuadPart;
		record.kind = kind;
		wcsncpy_s(record.stage, stage, _TRUNCATE);
		state.records.emplace_back(record);
	}

public:
	static void Init() { GetState(); }
	static bool IsEnabled() { return GetState().enabled; }
	static bool HasFirstSample() {
		auto& state = GetState();
		if (!state.enabled) {
			return false;
		}
		std::lock_guard<std::mutex> lock(state.mutex);
		return state.firstSampleLogged;
	}
	static void Log(const wchar_t* stage) { Add(stage, L"PERF"); }

	static void LogFirstSample(const wchar_t* stage) {
		Add(stage, L"FIRST SAMPLE RECEIVED", &GetState().firstSampleLogged);
	}

	static void LogFirstFrame(const wchar_t* renderer) {
		Add(renderer, L"FIRST FRAME PRESENTED", &GetState().firstFrameLogged);
	}

	static void Flush() {
		auto& state = GetState();
		if (!state.enabled) {
			return;
		}
		std::lock_guard<std::mutex> lock(state.mutex);
		if (state.flushed) {
			return;
		}
		state.flushed = true;
		FILE* file = nullptr;
		if (_wfopen_s(&file, state.path, L"w, ccs=UTF-8") == 0) {
			fwprintf(file, L"=== Startup Performance Benchmark (application constructor origin) ===\n");
			fwprintf(file, L"QPC origin=%lld frequency=%lld\n", state.start.QuadPart, state.freq.QuadPart);
			for (const auto& record : state.records) {
				if (record.kind[0] == L'P') {
					fwprintf(file, L"[PERF %8.2f ms] %ls\n", record.ms, record.stage);
				} else {
					fwprintf(file, L"[%ls: %8.2f ms] %ls\n", record.kind, record.ms, record.stage);
				}
			}
			fclose(file);
		}
	}
};
