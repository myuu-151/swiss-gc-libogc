/*
 * DVDReadPrioLibogc -- high-memory "env-swap" shim for libogc's DVD_ReadPrio.
 *
 * The problem: libogc reinstalls the PPC exception vectors at their fixed
 * addresses (0x100-0x1800) when it boots, which flattens Swiss's entire
 * low-memory world -- the VAR_* state at 0x9xx AND the base runtime that lives
 * at 0x80000C00-0x80003000 (frag_get / do_read_write / the jump table). So we
 * cannot just call Swiss's read code: it's gone.
 *
 * This blob is installed via installPatch2() into Swiss's high reserved region,
 * which libogc never touches (proven on hardware: a sentinel here returns -77
 * cleanly). Swiss snapshots its finished low-memory image (the VAR_AREA staging
 * array, exactly what install_code() blasts to 0x80000000) into our `backup`
 * buffer at boot -- see patcher.c install_code().
 *
 * On each call we:
 *   1. mask external interrupts (clear MSR[EE]),
 *   2. save libogc's live low memory (0x80000000..+0x3100) into `scratch`,
 *   3. restore Swiss's low memory from `backup` (so VAR_* + base runtime + the
 *      restored exception vectors are all valid again),
 *   4. branch to the base-runtime jump-table slot at 0x80000D14
 *      (`b DVDReadPrio_libogc`) which walks the frags and does the polled read,
 *   5. flush the read buffer back to memory,
 *   6. restore libogc's low memory from `scratch`,
 *   7. unmask interrupts and return the byte count.
 *
 * do_read_write() is polled (no interrupts), so masking EE for the duration is
 * safe. Any exception during the read hits Swiss's own (restored) handlers, not
 * garbage. The blob is position-independent: installPatch2() memcpy()s it to a
 * dynamic address without applying relocations, so we derive `backup`/`scratch`
 * from our own PC.
 *
 * Entry (libogc DVD_ReadPrio ABI, verified by disassembly):
 *   r3=block  r4=buffer  r5=length  r7:r8=s64 offset (r8=low)  r9=prio
 *   LR = caller's return address (the patched first instruction is `b` here,
 *   so LR still points at DVD_ReadPrio's caller -- we finish the job and blr).
 */

	.set	LOWMEM_BASE_HI,	0x8000		/* 0x80000000 */
	.set	LOWMEM_WORDS,	0x3100/4	/* 0xC40 words to copy   */
	.set	LOWMEM_LINES,	0x3100/32	/* 0x188 cache lines     */
	.set	CURRENT_DISC,	0x09B0		/* *(u8*)0x800009B0      */
	.set	DISC_READ_LO,	0x0D14		/* base.S jump table: b DVDReadPrio_libogc */

	.globl	DVDReadPrioLibogc
DVDReadPrioLibogc:
	b	shim_start			/* entry (offset 0) -- jump past the buffers */

	/* Snapshot buffers live inside the blob (high memory libogc never touches).
	   backup is filled by Swiss at boot; keep its offset (0x20) in sync with
	   DVD_READPRIO_BACKUP_OFF in patcher.h. */
	.balign	32
	.globl	DVDReadPrioLibogc_backup
DVDReadPrioLibogc_backup:
	.space	0x3100
DVDReadPrioLibogc_scratch:
	.space	0x3100

shim_start:
	/* --- prologue: frame + save non-volatiles we keep across the read --- */
	stwu	r1, -64(r1)
	mflr	r0
	stw	r0, 68(r1)			/* caller's return address */
	stmw	r25, 36(r1)			/* r25..r31 */

	mr	r31, r4				/* buffer */
	mr	r30, r5				/* length */
	mr	r29, r8				/* offset (low 32 bits) */

	/* --- PIC: derive backup/scratch addresses from our own PC --- */
	bl	1f
1:	mflr	r10
	addis	r26, r10, (DVDReadPrioLibogc_backup - 1b)@ha
	addi	r26, r26, (DVDReadPrioLibogc_backup - 1b)@l	/* r26 = backup  */
	addis	r25, r10, (DVDReadPrioLibogc_scratch - 1b)@ha
	addi	r25, r25, (DVDReadPrioLibogc_scratch - 1b)@l	/* r25 = scratch */

	/* --- mask external interrupts (clear MSR[EE]) --- */
	mfmsr	r28
	rlwinm	r3, r28, 0, 17, 15		/* clear bit 16 (EE) */
	mtmsr	r3
	isync

	/* --- save libogc low memory -> scratch --- */
	lis	r3, LOWMEM_BASE_HI
	mr	r4, r25
	li	r5, LOWMEM_WORDS
	mtctr	r5
2:	lwz	r0, 0(r3)
	stw	r0, 0(r4)
	addi	r3, r3, 4
	addi	r4, r4, 4
	bdnz	2b

	/* --- restore Swiss low memory <- backup --- */
	mr	r3, r26
	lis	r4, LOWMEM_BASE_HI
	li	r5, LOWMEM_WORDS
	mtctr	r5
3:	lwz	r0, 0(r3)
	stw	r0, 0(r4)
	addi	r3, r3, 4
	addi	r4, r4, 4
	bdnz	3b

	bl	cachesync_low			/* make the restored code executable */

	/* --- call base-runtime DVDReadPrio_libogc(file, buf, len, offset) --- */
	lis	r3, LOWMEM_BASE_HI
	lbz	r3, CURRENT_DISC(r3)		/* file = current disc number */
	mr	r4, r31				/* buffer */
	mr	r5, r30				/* length */
	mr	r6, r29				/* offset */
	lis	r0, LOWMEM_BASE_HI
	ori	r0, r0, DISC_READ_LO
	mtctr	r0
	bctrl					/* -> 0x80000D14 -> DVDReadPrio_libogc */
	mr	r27, r3				/* bytes read */

	/* --- flush the read buffer back to memory (dcbf buf..buf+len) --- */
	mr	r3, r31
	add	r4, r31, r30
4:	dcbf	0, r3
	addi	r3, r3, 32
	cmplw	r3, r4
	blt	4b
	sync

	/* --- restore libogc low memory <- scratch --- */
	mr	r3, r25
	lis	r4, LOWMEM_BASE_HI
	li	r5, LOWMEM_WORDS
	mtctr	r5
5:	lwz	r0, 0(r3)
	stw	r0, 0(r4)
	addi	r3, r3, 4
	addi	r4, r4, 4
	bdnz	5b

	bl	cachesync_low			/* make libogc's code executable again */

	/* --- unmask interrupts, return byte count --- */
	mtmsr	r28
	isync
	mr	r3, r27

	/* --- epilogue --- */
	lmw	r25, 36(r1)
	lwz	r0, 68(r1)
	mtlr	r0
	addi	r1, r1, 64
	blr

/* Flush dcache + invalidate icache over 0x80000000..+0x3100 so freshly
   restored instructions are the ones that execute. Clobbers r3,r4,r5,CTR,LR. */
cachesync_low:
	lis	r3, LOWMEM_BASE_HI
	li	r4, LOWMEM_LINES
	mtctr	r4
	mr	r5, r3
cs1:	dcbst	0, r5
	addi	r5, r5, 32
	bdnz	cs1
	sync
	lis	r5, LOWMEM_BASE_HI
	mtctr	r4
cs2:	icbi	0, r5
	addi	r5, r5, 32
	bdnz	cs2
	isync
	blr
