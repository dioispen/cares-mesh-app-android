import java.io.BufferedOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;

/**
 * Rewrites a ZIP archive with its entries sorted by name, copying every entry's local record
 * (header, compressed data and data descriptor) byte for byte. Only the entry order and the
 * offsets in the central directory change; no entry is recompressed.
 *
 * <p>The release AAB needs this because AGP adds the native debug symbols
 * ({@code BUNDLE-METADATA/com.android.tools.build.debugsymbols/<abi>/*.so.sym}) in the order a
 * directory walk returns them, and that order depends on the build host's filesystem: two
 * replicas of the same commit produced the same entries in a different order on GitHub's AWS and
 * Azure runners. Sorting makes the order independent of the host.
 *
 * <p>Usage: {@code java NormalizeZipEntryOrder.java INPUT.zip OUTPUT.zip}. Multi-disk and Zip64
 * archives are rejected rather than guessed at; the AAB is far below the Zip64 limits.
 */
public final class NormalizeZipEntryOrder {
  private static final int LOCAL_HEADER = 0x04034b50;
  private static final int CENTRAL_HEADER = 0x02014b50;
  private static final int END_OF_CENTRAL_DIRECTORY = 0x06054b50;
  private static final int ZIP64_LOCATOR = 0x07064b50;
  private static final int EOCD_SIZE = 22;
  private static final int DATA_DESCRIPTOR_FLAG = 1 << 3;

  /** One entry: its central directory record, and where its local record sits in the input. */
  private record Entry(byte[] name, byte[] centralRecord, int localOffset, int compressedSize, boolean hasDescriptor) {}

  public static void main(String[] args) throws IOException {
    if (args.length != 2) {
      System.err.println("usage: java NormalizeZipEntryOrder.java INPUT.zip OUTPUT.zip");
      System.exit(2);
    }
    Path input = Path.of(args[0]);
    Path output = Path.of(args[1]);
    byte[] zip = Files.readAllBytes(input);
    ByteBuffer buf = ByteBuffer.wrap(zip).order(ByteOrder.LITTLE_ENDIAN);

    int eocd = findEndOfCentralDirectory(buf);
    int diskNumber = u16(buf, eocd + 4);
    int centralDirectoryDisk = u16(buf, eocd + 6);
    int entriesOnDisk = u16(buf, eocd + 8);
    int totalEntries = u16(buf, eocd + 10);
    long centralDirectorySize = u32(buf, eocd + 12);
    long centralDirectoryOffset = u32(buf, eocd + 16);
    if (diskNumber != 0 || centralDirectoryDisk != 0 || entriesOnDisk != totalEntries) {
      fail("multi-disk archives are not supported");
    }
    if (totalEntries == 0xFFFF || centralDirectorySize == 0xFFFFFFFFL || centralDirectoryOffset == 0xFFFFFFFFL
        || (eocd >= 20 && buf.getInt(eocd - 20) == ZIP64_LOCATOR)) {
      fail("Zip64 archives are not supported");
    }
    if (centralDirectoryOffset + centralDirectorySize != eocd) {
      fail("unexpected bytes between the central directory and its end record");
    }

    List<Entry> entries = readCentralDirectory(buf, (int) centralDirectoryOffset, totalEntries, eocd);
    int[] localLengths = measureLocalRecords(buf, entries, (int) centralDirectoryOffset);

    List<Integer> order = new ArrayList<>();
    for (int i = 0; i < entries.size(); i++) {
      order.add(i);
    }
    order.sort(Comparator.comparing(i -> entries.get(i).name(), Arrays::compareUnsigned));
    for (int i = 1; i < order.size(); i++) {
      if (Arrays.equals(entries.get(order.get(i - 1)).name(), entries.get(order.get(i)).name())) {
        fail("duplicate entry name: " + new String(entries.get(order.get(i)).name(), java.nio.charset.StandardCharsets.UTF_8));
      }
    }

    long written = 0;
    int[] newOffsets = new int[entries.size()];
    try (OutputStream out = new BufferedOutputStream(Files.newOutputStream(output), 1 << 20)) {
      for (int i : order) {
        Entry entry = entries.get(i);
        newOffsets[i] = Math.toIntExact(written);
        out.write(zip, entry.localOffset(), localLengths[i]);
        written += localLengths[i];
      }
      int newCentralDirectoryOffset = Math.toIntExact(written);
      for (int i : order) {
        byte[] record = entries.get(i).centralRecord().clone();
        ByteBuffer.wrap(record).order(ByteOrder.LITTLE_ENDIAN).putInt(42, newOffsets[i]);
        out.write(record);
        written += record.length;
      }
      byte[] end = Arrays.copyOfRange(zip, eocd, zip.length);
      ByteBuffer.wrap(end).order(ByteOrder.LITTLE_ENDIAN).putInt(16, newCentralDirectoryOffset);
      out.write(end);
      written += end.length;
    }
    if (written != zip.length) {
      fail("output size " + written + " differs from input size " + zip.length);
    }
  }

  private static int findEndOfCentralDirectory(ByteBuffer buf) {
    int lowest = Math.max(0, buf.capacity() - EOCD_SIZE - 0xFFFF);
    for (int p = buf.capacity() - EOCD_SIZE; p >= lowest; p--) {
      if (buf.getInt(p) == END_OF_CENTRAL_DIRECTORY && p + EOCD_SIZE + u16(buf, p + 20) == buf.capacity()) {
        return p;
      }
    }
    fail("end of central directory record not found");
    return -1;
  }

  private static List<Entry> readCentralDirectory(ByteBuffer buf, int offset, int count, int end) {
    List<Entry> entries = new ArrayList<>(count);
    int p = offset;
    for (int i = 0; i < count; i++) {
      if (p + 46 > end || buf.getInt(p) != CENTRAL_HEADER) {
        fail("malformed central directory at offset " + p);
      }
      int flags = u16(buf, p + 8);
      long compressedSize = u32(buf, p + 20);
      int nameLength = u16(buf, p + 28);
      int extraLength = u16(buf, p + 30);
      int commentLength = u16(buf, p + 32);
      long localOffset = u32(buf, p + 42);
      int length = 46 + nameLength + extraLength + commentLength;
      if (compressedSize == 0xFFFFFFFFL || localOffset == 0xFFFFFFFFL) {
        fail("Zip64 entries are not supported");
      }
      byte[] record = new byte[length];
      buf.get(p, record);
      byte[] name = Arrays.copyOfRange(record, 46, 46 + nameLength);
      entries.add(new Entry(name, record, (int) localOffset, (int) compressedSize, (flags & DATA_DESCRIPTOR_FLAG) != 0));
      p += length;
    }
    if (p != end) {
      fail("central directory size does not match its entries");
    }
    return entries;
  }

  /**
   * The local record of each entry runs up to the next entry's local record (or the central
   * directory), so data descriptors are copied without parsing their optional signature. Each
   * extent is checked to start with a local header for the same name and to be long enough.
   */
  private static int[] measureLocalRecords(ByteBuffer buf, List<Entry> entries, int centralDirectoryOffset) {
    List<Integer> byOffset = new ArrayList<>();
    for (int i = 0; i < entries.size(); i++) {
      byOffset.add(i);
    }
    byOffset.sort(Comparator.comparingInt(i -> entries.get(i).localOffset()));
    if (!byOffset.isEmpty() && entries.get(byOffset.get(0)).localOffset() != 0) {
      fail("unexpected bytes before the first entry");
    }
    int[] lengths = new int[entries.size()];
    for (int k = 0; k < byOffset.size(); k++) {
      int i = byOffset.get(k);
      Entry entry = entries.get(i);
      int start = entry.localOffset();
      int next = k + 1 < byOffset.size() ? entries.get(byOffset.get(k + 1)).localOffset() : centralDirectoryOffset;
      if (start + 30 > next || buf.getInt(start) != LOCAL_HEADER) {
        fail("no local header at offset " + start);
      }
      int nameLength = u16(buf, start + 26);
      int extraLength = u16(buf, start + 28);
      byte[] localName = new byte[nameLength];
      buf.get(start + 30, localName);
      if (!Arrays.equals(localName, entry.name())) {
        fail("local header name does not match the central directory at offset " + start);
      }
      long minimum = 30L + nameLength + extraLength + entry.compressedSize() + (entry.hasDescriptor() ? 12 : 0);
      if (next - start < minimum) {
        fail("local record at offset " + start + " is shorter than its header says");
      }
      lengths[i] = next - start;
    }
    return lengths;
  }

  private static int u16(ByteBuffer buf, int offset) {
    return Short.toUnsignedInt(buf.getShort(offset));
  }

  private static long u32(ByteBuffer buf, int offset) {
    return Integer.toUnsignedLong(buf.getInt(offset));
  }

  private static void fail(String message) {
    System.err.println("error: " + message);
    System.exit(1);
  }
}
