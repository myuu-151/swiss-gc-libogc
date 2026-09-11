/*
 * DVDReadPrioLibogc -- standalone high-memory shim for libogc DVD_ReadPrio.
 *
 * Installed into Swiss's high installPatch2 region (which libogc never touches),
 * unlike the base runtime at LO_RESERVE 0x80000C00-0x1800 that libogc's exception
 * vectors overwrite. The game's DVD_ReadPrio is patched to branch here.
 *
 * STEP 1 (this build): just return a sentinel (-77) so we can confirm on hardware
 * that a high shim is actually reached and un-clobbered. Once octlog shows rc=-77,
 * the real synchronous SD read gets built in here.
 */
	.globl DVDReadPrioLibogc
DVDReadPrioLibogc:
	li	3, -77
	blr
