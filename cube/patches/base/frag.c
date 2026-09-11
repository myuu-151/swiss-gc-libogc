/* 
 * Copyright (c) 2021-2022, Extrems <extrems@extremscorner.org>
 * 
 * This file is part of Swiss.
 * 
 * Swiss is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 * 
 * Swiss is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * with Swiss.  If not, see <https://www.gnu.org/licenses/>.
 */

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include "common.h"
#include "dolphin/os.h"
#include "frag.h"

#define DEVICE_DISC 0
#ifndef DEVICE_PATCHES
#define DEVICE_PATCHES DEVICE_DISC
#endif

__attribute((weak))
bool do_read_write_async(void *buffer, uint32_t length, uint32_t offset, uint64_t sector, bool write, frag_callback callback)
{
	return false;
}

__attribute((weak))
int do_read_write(void *buffer, uint32_t length, uint32_t offset, uint64_t sector, bool write)
{
	return 0;
}

__attribute((weak))
void end_read(void)
{
	return;
}

__attribute((weak))
void reset_device(void)
{
	end_read();
}

static bool frag_get(int file, uint32_t offset, size_t size, frag_t *frag)
{
	const frag_t *frags = *(frag_t **)VAR_FRAG_LIST;

	if (!frags)
		return false;

	for (int i = 0; frags[i].size; i++) {
		if (file != frags[i].file)
			continue;
		if (offset < frags[i].offset || offset >= frags[i].offset + frags[i].size) {
			size = MIN(size, OSRoundUp32B(frags[i].offset - offset));
			continue;
		}

		frag->offset = offset - frags[i].offset;
		frag->size = MIN(size, OSRoundUp32B(frags[i].size) - frag->offset);
		frag->data = frags[i].data;
		return true;
	}

	return false;
}

int frag_get_list(int file, const frag_t **frag)
{
	const frag_t *frags = *(frag_t **)VAR_FRAG_LIST;
	int count = 0;

	if (!frags)
		return 0;

	for (int i = 0; frags[i].size; i++) {
		if (file != frags[i].file || frags[i].device != DEVICE_DISC) {
			if (!count) continue;
			else break;
		} else if (!count)
			*frag = &frags[i];
		count++;
	}

	return count;
}

bool is_frag_patch(int file, uint32_t offset, size_t size)
{
	frag_t frag;
	return frag_get(file, offset, size, &frag) && frag.device == DEVICE_PATCHES;
}

bool frag_read_write_async(int file, void *buffer, uint32_t length, uint32_t offset, bool write, frag_callback callback)
{
	frag_t frag;

	if (frag_get(file, offset, length, &frag)) {
		if (frag.device == DEVICE_PATCHES)
			return do_read_write_async(buffer, frag.size, frag.offset, frag.sector, write, callback);
		else if (!write)
			return do_read_disc(buffer, frag.size, frag.offset, &frag, callback);
	#ifdef DIRECT_DISC
	} else if (!write) {
		return do_read_disc(buffer, length, offset, NULL, callback);
	#endif
	}

	return false;
}

int frag_read_complete(int file, void *buffer, uint32_t length, uint32_t offset)
{
	int i = 0;

	while (i < length) {
		int read = frag_read(file, buffer + i, length - i, offset + i);
		if (!read) break;
		i += read;
	}

	return i;
}

bool frag_read_patch(int file, void *buffer, uint32_t length, uint32_t offset, frag_callback callback)
{
	frag_t frag;

	if (frag_get(file, offset, length, &frag)) {
		if (frag.device == DEVICE_PATCHES)
			return true;
		else
			do_read_disc(buffer, frag.size, frag.offset, &frag, callback);
	#ifdef DIRECT_DISC
	} else {
		do_read_disc(buffer, length, offset, NULL, callback);
	#endif
	}

	return false;
}

int frag_read_write(int file, void *buffer, uint32_t length, uint32_t offset, bool write)
{
	frag_t frag;

	if (frag_get(file, offset, length, &frag) && frag.device == DEVICE_PATCHES)
		return do_read_write(buffer, frag.size, frag.offset, frag.sector, write);

	return 0;
}
/*
 * Swiss fork addition: serve libogc's synchronous DVD_ReadPrio() straight from
 * the mounted disc image, so an on-disc libogc ISO reads its assets under Swiss.
 * The game's DVD_ReadPrio is patched (patcher.c) to branch to the base-runtime
 * jump-table slot `b DVDReadPrio_libogc`, which lands here. Args arrive in
 * libogc's register layout (verified by disassembly): r4=buffer, r5=length,
 * r7=offset_hi, r8=offset, r9=prio, with r6 an unused gap -- so this C parameter
 * order maps the incoming registers correctly.
 */
int DVDReadPrio_libogc(void *block, void *buffer, int length,
                       int r6_unused, int offset_hi, int offset, int prio)
{
	void *uncached = (void *)((uintptr_t)buffer | 0xC0000000);
	int read = frag_read_complete(*VAR_CURRENT_DISC, uncached, length, offset);

	/* Drop stale cached lines so the game's cached reads refetch from memory. */
	for (int i = 0; i < length; i += 32)
		asm volatile ("dcbi 0,%0" :: "r"((uint8_t *)buffer + i) : "memory");
	asm volatile ("sync");

	return read >= length ? length : -100;  /* -100 = shim ran, frag short; -1 = shim never ran */
}

