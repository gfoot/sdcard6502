# 6502 FAT32 Library

Building on the basic SD code in the tuturials in this repo, I have implemented
basic FAT32 filesystem support.  There are some corners cut but nothing that
should affect usage with SD cards.

# Example program

See [test\_dumpfile.s](../src/test\_dumpfile.s) for an example of reading a file.

It initializes things, then searches the root directory for a folder called "subfoldr",
then searches that subfolder for a file called "deepfile.txt", then loads it and prints
its contents to the LCD.

Also see [test\_savefile.s](../src/test\_savefile.s) for an example of creating a new file and writing to it.

It also initializes things, then searches the root directory for a folder called "subfoldr",
it then checks to see if a file "SAVETEST.txt" exists, 
if it does, then it deletes it.
after that, it creates a new "SAVETEST.txt",
and then it writes this dummy text to it:
```
Hello World!
This is text saved from a 6502 computer to an SD Card!

```  


This covers most things you'd need to do - of the APIs provided, it just skips
enumerating files in a directory one by one, and reading a file byte by byte instead
of all at once.

# Setup

Mostly you just need to .include the library code in your source and call the
right functions.

Your code also needs to provide some memory for the SD and FAT32 libraries to
use, by defining some specific symbols.  See the example program for more
details.


# High-level API

## fat32\_init

This initializes the library.  The SD library needs to be initialized first.

On return, the carry is set if there was an error, and in that case you can read an
error code from `fat32_errorstage` that may help diagnosing what the problem was
(probably some issue with the formatting of the SD card).

## fat32\_openroot

Opens the root directory, preparing to enumerate or search its contents.

## fat32\_finddirent

With a directory open, scans for an entry matching a given filename.

X and Y should point to the filename in memory, with the high byte of the address in Y.

The carry will be clear on success, or set if the directory entry was not found.

Note that the filename data you provide should match the format used in FAT32
directory entries, i.e. 8 bytes of capitalized filename padded with spaces,
followed by 3 bytes of capitalized extension padded with spaces.  Note
especially that it's not null-terminated, mustn't be lower case, and doesn't
include an explicit dot.

## fat32\_allocatefile

This allocates all the clusters for a new file.

The 16-bit file size to allocate (in bytes) should be in `fat32_bytesremaining` and `fat32_bytesremaining+1` before running.

Note: this also changes fat32_bytesremaining, so make sure to stash it before running this, and restore it before you create a directory entry.

## fat32\_opendirent

After `finddirent` or `readdirent`, this opens the active directory entry
as referenced by `zp_sd_address`.

If the object is a directory, then subsequent calls to `finddirent` or `readdirent` will  
iterate over the subdirectory.

If the object is a file, the file access APIs can then be used to read its contents,
and directory iteration APIs won't work any more.

## fat32\_open\_cd

Opens the previously opened directory (current directory)

This allows directory iteration APIs to work again after reading/writing a file

## fat32\_deletefile

Removes a file from the card, as well as clearing all the clusters
it used from the FAT.  

Run this after `finddirent` succeeds, not after `opendirent`!

If you are going to read/write a directory entry after this, you will need to re-open the directory! (`fat32_open_cd`)

## fat32\_markdeleted

Marks the file that was found using `finddirent` as "deleted".

This is also used in `deletefile`.

(does not clear FAT for the file)

## fat32\_writedirent

Creates and writes a new directory entry in the open directory.

Make sure that you've allocated space for a file before running this!

input variables:
`fat32_filenamepointer` points to the filename to write, and
`fat32_bytesremaining` is the file size in bytes (16 bit)  

At the moment, folder creation is not supported, only files.

## fat32\_readdirent

Advances to the next entry in the directory, allowing for listing directories
without knowing in advance what files they contain.

On success the carry is clear and `zp_sd_address` points at the directory entry
in memory, in raw byte format used by FAT32.

Otherwise, if there are no more entries in the directory, then the carry is set.

## fat32\_file\_read

Reads an entire file into memory, after it has been opened via `opendirent` above.

Pass the target address at `fat32_address`.

The file size is rounded up to the next multiple of 512 bytes, so data in
memory beyond the strict end of the file may also be overwritten.

## fat32\_file\_write

Writes an entire file from memory to the SD card, after it has been opened via `opendirent`.

The memory location to start from is in `fat32_address`

Run this after running `writedirent`!

The file size is rounded up to the next multiple of 512 bytes, but this isn't a problem here because the exact file size is already written by `writedirent`.

# Caveats

This is a minimal implementation to support loading and saving files on SD cards, and a lot
of corners have been cut:

* Only supports FAT32 - not earlier revisions
* The partition must be a type 12 primary partition
* The FAT32 sector size must be 512 bytes
* Long filenames are ignored
* Not much consistency checking is done


# Note on exfat

I also have an exfat implementation but my understanding is that exfat is
patented by Microsoft and cannot be freely shared.  Exceptions were made for
Linux implementations and members of the SD Consortium, but in general it is
still not free to implement, so I can't share that code.

