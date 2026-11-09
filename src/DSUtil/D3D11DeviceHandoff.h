/*
 * (C) 2026 see Authors.txt
 *
 * This file is part of MPC-BE.
 *
 * MPC-BE is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3 of the License, or
 * (at your option) any later version.
 *
 * MPC-BE is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

#pragma once

#include <d3d11.h>
#include <chrono>
#include <condition_variable>
#include <mutex>

// One-shot, process-wide hand-off of a D3D11 device created ahead of time.
//
// When the player is launched with a file, a startup thread loads the GPU
// driver by creating a device. The first device in a process is by far the
// most expensive one, and the D3D11 video decoder later needs a device of its
// own with the same parameters. Instead of discarding the startup device and
// creating another one on the playback-critical path, the startup thread
// offers it here and the decoder takes it if the adapter and creation flags
// match. Anything not taken is released once the file is open.
class CD3D11DeviceHandoff
{
	struct State {
		std::mutex mutex;
		std::condition_variable cv;
		ID3D11Device* pDevice = nullptr;
		LUID luid = {};
		bool bPending = false;
		bool bClosed = false;
	};

	static State& Get() {
		static State state;
		return state;
	}

public:
	// Creation flags the D3D11 decoder uses (see CD3D11Decoder::CreateD3D11Device).
	static constexpr UINT DecoderFlags = D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT;

	// The producer is about to create a device; Take() waits for it briefly
	// instead of creating a competing device while the driver loads.
	static void BeginPending() {
		auto& s = Get();
		std::lock_guard<std::mutex> lock(s.mutex);
		s.bPending = true;
	}

	// Publish a device (may be null on failure) and end the pending state.
	static void Offer(ID3D11Device* pDevice, const LUID& luid) {
		auto& s = Get();
		{
			std::lock_guard<std::mutex> lock(s.mutex);
			if (s.pDevice) {
				s.pDevice->Release();
				s.pDevice = nullptr;
			}
			if (pDevice && !s.bClosed) {
				pDevice->AddRef();
				s.pDevice = pDevice;
				s.luid = luid;
			}
			s.bPending = false;
		}
		s.cv.notify_all();
	}

	// Returns an owned reference to the offered device when it was created on
	// the adapter with this LUID with the given flags, otherwise nullptr.
	static ID3D11Device* Take(const LUID& luid, UINT flags) {
		auto& s = Get();
		std::unique_lock<std::mutex> lock(s.mutex);
		if (s.bPending) {
			s.cv.wait_for(lock, std::chrono::milliseconds(1000), [&s] { return !s.bPending; });
		}
		ID3D11Device* pDevice = s.pDevice;
		if (!pDevice || s.luid.LowPart != luid.LowPart || s.luid.HighPart != luid.HighPart
				|| pDevice->GetCreationFlags() != flags) {
			return nullptr;
		}
		s.pDevice = nullptr;
		return pDevice;
	}

	// Drop any device that was not taken, and any offered later.
	static void Clear() {
		auto& s = Get();
		ID3D11Device* pDevice = nullptr;
		{
			std::lock_guard<std::mutex> lock(s.mutex);
			pDevice = s.pDevice;
			s.pDevice = nullptr;
			s.bPending = false;
			s.bClosed = true;
		}
		s.cv.notify_all();
		if (pDevice) {
			pDevice->Release();
		}
	}
};
