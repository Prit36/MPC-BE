// Standalone regression check: compile with MSVC /std:c++17 /EHsc.
#include "../src/DSUtil/PerfTimer.h"
#include <string>
#include <thread>
#include <cassert>

int wmain(int argc, wchar_t** argv)
{
	assert(argc == 2);
	const bool enabled = wcscmp(argv[1], L"enabled") == 0;
	assert(PerfTimer::IsEnabled() == enabled);
	wchar_t path[MAX_PATH] = {};
	GetEnvironmentVariableW(L"MPCBE_STARTUP_TRACE", path, MAX_PATH);
	if (enabled) {
		assert(GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES);
	}
	wchar_t transient[] = L"copied stage";
	PerfTimer::Log(transient);
	transient[0] = L'X';
	std::vector<std::thread> workers;
	for (int i = 0; i < 8; ++i) {
		workers.emplace_back([] {
			PerfTimer::LogFirstSample(L"sample milestone");
			PerfTimer::LogFirstFrame(L"presentation milestone");
			for (int j = 0; j < 50; ++j) {
				PerfTimer::Log(L"concurrent stage");
			}
		});
	}
	for (auto& worker : workers) {
		worker.join();
	}
	// Exercise bounded storage without growing it during a long playback.
	for (int i = 0; i < 10000; ++i) {
		PerfTimer::Log(L"overflow stage");
	}
	if (enabled) {
		assert(GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES);
	}
	PerfTimer::Flush();
	PerfTimer::Log(L"after flush");
	PerfTimer::Flush();
	if (enabled) {
		FILE* file = nullptr;
		assert(_wfopen_s(&file, path, L"r, ccs=UTF-8") == 0);
		std::wstring trace;
		wchar_t line[512];
		int records = 0;
		while (fgetws(line, 512, file)) {
			trace += line;
			if (line[0] == L'[') { ++records; }
		}
		fclose(file);
		assert(records == 512);
		assert(trace.find(L"copied stage") != std::wstring::npos);
		assert(trace.find(L"Xopied stage") == std::wstring::npos);
		assert(trace.find(L"after flush") == std::wstring::npos);
		for (const auto* marker : { L"FIRST SAMPLE RECEIVED", L"FIRST FRAME PRESENTED" }) {
			const auto pos = trace.find(marker);
			assert(pos != std::wstring::npos);
			assert(trace.find(marker, pos + 1) == std::wstring::npos);
		}
	}
	return 0;
}
