//          Copyright Yazan Dabain 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module elf.sections.debugline;

// this implementation follows the DWARF v3 documentation

import std.exception;
import std.range;
import std.conv : to;
import elf, elf.meta;

private import elf.sections.debugline32, elf.sections.debugline64;

alias enforce = enforceEx!ELFException;

struct DebugLine {
	private LineProgram[] m_lps;

	private enum uint DWARF_64BIT_FLAG = 0xffff_ffff;

	this(ELFSection section) {
		this.m_lps = new LineProgram[0];

		ubyte[] lineProgramContents = section.contents();

		while (!lineProgramContents.empty) {
			LineProgram lp;

			// detect dwarf 32bit or 64bit
			uint initialLength = * cast(uint*) lineProgramContents.ptr;
			if (initialLength == DWARF_64BIT_FLAG) {
				LineProgramHeader64L data = * cast(LineProgramHeader64L*) lineProgramContents.ptr;
				lp.m_header = new LineProgramHeader64(data);
			} else {
				LineProgramHeader32L data = * cast(LineProgramHeader32L*) lineProgramContents.ptr;
				lp.m_header = new LineProgramHeader32(data);
			}

			// start reading sections
			lp.m_standardOpcodeLengths = new ubyte[lp.m_header.opcodeBase - 1];
			foreach (i; 0 .. lp.m_standardOpcodeLengths.length) {
				lp.m_standardOpcodeLengths[i] = lineProgramContents[lp.m_header.datasize + i .. lp.m_header.datasize + i + 1][0];
			}

			lp.m_files = new string[0];
			lp.m_dirs = new string[0];

			auto filesSection = lineProgramContents[lp.m_header.datasize + lp.m_standardOpcodeLengths.length .. $];

			while (filesSection[0] != 0) {
				lp.m_dirs ~= (cast(char*) filesSection.ptr).to!string();
				filesSection = filesSection[lp.m_dirs[$ - 1].length + 1 .. $];
			}

			filesSection.popFront();

			while (filesSection[0] != 0) {
				lp.m_files ~= (cast(char*) filesSection.ptr).to!string();
				filesSection = filesSection[lp.m_files[$ - 1].length + 1 .. $];

				auto dirIndex = filesSection.readULEB128();
				auto lastMod = filesSection.readULEB128();
				auto fileLength = filesSection.readULEB128();
			}

			static if (__VERSION__ < 2065) { // bug workaround for older versions
				auto startOffset = lp.m_header.is32bit() ? uint.sizeof * 2 + ushort.sizeof : uint.sizeof + 2 * ulong.sizeof + ushort.sizeof;
				auto endOffset   = lp.m_header.is32bit() ? uint.sizeof : uint.sizeof + ulong.sizeof;
			} else {
				auto startOffset = lp.m_header.is32bit() ? LineProgramHeader32L.minimumInstructionLength.offsetof : LineProgramHeader64L.minimumInstructionLength.offsetof;
				auto endOffset   = lp.m_header.is32bit() ? LineProgramHeader32L.unitLength.sizeof : LineProgramHeader64L.unitLength.offsetof + LineProgramHeader64L.unitLength.sizeof;
			}

			auto program = lineProgramContents[startOffset + lp.m_header.headerLength() .. endOffset + lp.m_header.unitLength()];

			buildMachine(lp, program);
			m_lps ~= lp;

			lineProgramContents = lineProgramContents[endOffset + lp.m_header.unitLength() .. $];
		}

	}

	private void buildMachine(ref LineProgram lp, ubyte[] program) {
		import std.range;

		Machine m;
		m.isStatement = lp.m_header.defaultIsStatement();

		lp.m_addresses = new AddressInfo[0];

		// import std.stdio, std.string;
		// alias trace = writeln;

		while (!program.empty) {
			ubyte opcode = program.read!ubyte();

			if (opcode < lp.m_header.opcodeBase) {

				switch (opcode) with (StandardOpcode) {
					case extendedOp:
						ulong len = program.readULEB128();
						ubyte eopcode = program.read!ubyte();

						switch (eopcode) with (ExtendedOpcode) {
							case endSequence:
								m.isEndSequence = true;
								// trace("endSequence ", "0x%x".format(m.address));
								lp.m_addresses ~= AddressInfo(m.line, m.fileIndex, m.address);
								m = Machine.init;
								m.isStatement = lp.m_header.defaultIsStatement;
								break;

							case setAddress:
								ulong address = program.read!ulong();
								// trace("setAddress ", "0x%x".format(address));
								m.address = address;
								break;

							case defineFile:
								auto file = (cast(char*) program.ptr).to!string();
								program = program[file.length + 1 .. $];
								auto dirIndex = program.readULEB128();
								auto fileMod = program.readULEB128();
								auto fileSize = program.readULEB128();
								// trace("defineFile");
								break;

							default:
								throw new ELFException("invalid extended opcode");
						}

						break;

					case copy:
						// trace("copy");
						lp.m_addresses ~= AddressInfo(m.line, m.fileIndex, m.address);
						m.isBasicBlock = false;
						m.isPrologueEnd = false;
						m.isEpilogueBegin = false;
						break;

					case advancePC:
						ulong op = readULEB128(program);
						// trace("advancePC ", op * lp.m_header.minimumInstructionLength);
						m.address += op * lp.m_header.minimumInstructionLength;
						break;

					case advanceLine:
						long ad = readSLEB128(program);
						// trace("advanceLine ", ad);
						m.line += ad;
						break;

					case setFile:
						uint index = readULEB128(program).to!uint();
						// trace("setFile to ", index);
						m.fileIndex = index;
						break;

					case setColumn:
						uint col = readULEB128(program).to!uint();
						// trace("setColumn ", col);
						m.column = col;
						break;

					case negateStatement:
						// trace("negateStatement");
						m.isStatement = !m.isStatement;
						break;

					case setBasicBlock:
						// trace("setBasicBlock");
						m.isBasicBlock = true;
						break;

					case constAddPC:
						m.address += (255 - lp.m_header.opcodeBase) / lp.m_header.lineRange * lp.m_header.minimumInstructionLength;
						// trace("constAddPC ", "0x%x".format(m.address));
						break;

					case fixedAdvancePC:
						uint add = program.read!uint();
						// trace("fixedAdvancePC ", add);
						m.address += add;
						break;

					case setPrologueEnd:
						m.isPrologueEnd = true;
						// trace("setPrologueEnd");
						break;

					case setEpilogueBegin:
						m.isEpilogueBegin = true;
						// trace("setEpilogueBegin");
						break;

					case setISA:
						m.isa = readULEB128(program).to!uint();
						// trace("setISA ", m.isa);
						break;

					default:
						throw new ELFException("unimplemented/invalid opcode " ~ opcode.to!string);
				}

			} else {
				opcode -= lp.m_header.opcodeBase;
				auto ainc = (opcode / lp.m_header.lineRange) * lp.m_header.minimumInstructionLength;
				m.address += ainc;
				auto linc = lp.m_header.lineBase + (opcode % lp.m_header.lineRange);
				m.line += linc;

				// trace("special ", ainc, " ", linc);
				lp.m_addresses ~= AddressInfo(m.line, m.fileIndex, m.address);
			}
		}
	}

	const(LineProgram)[] programs() const {
		return m_lps;
	}
}

mixin(generateClassMixin!(LineProgramHeader, "LineProgramHeader32", LineProgramHeader32L, 32));
mixin(generateClassMixin!(LineProgramHeader, "LineProgramHeader64", LineProgramHeader64L, 64));

abstract class LineProgramHeader : PortableHeader {
	@property:
	@ReadFrom("unitLength") ulong unitLength();
	@ReadFrom("dwarfVersion") ushort dwarfVersion();
	@ReadFrom("headerLength") ulong headerLength();
	@ReadFrom("minimumInstructionLength") ubyte minimumInstructionLength();
	@ReadFrom("defaultIsStatement") bool defaultIsStatement();
	@ReadFrom("lineBase") byte lineBase();
	@ReadFrom("lineRange") ubyte lineRange();
	@ReadFrom("opcodeBase") ubyte opcodeBase();
}

private T read(T)(ref ubyte[] buffer) {
	T result = *(cast(T*) buffer[0 .. T.sizeof].ptr);
	buffer.popFrontExactly(T.sizeof);
	return result;
}

private ulong readULEB128(ref ubyte[] buffer) {
	import std.array;
	ulong val = 0;
	ubyte b;
	uint shift = 0;

	while (true) {
		b = buffer.read!ubyte();

		val |= (b & 0x7f) << shift;
		if ((b & 0x80) == 0) break;
		shift += 7;
	}

	return val;
}

unittest {
	ubyte[] data = [0xe5, 0x8e, 0x26, 0xDE, 0xAD, 0xBE, 0xEF];
	assert(readULEB128(data) == 624485);
	assert(data[] == [0xDE, 0xAD, 0xBE, 0xEF]);
}

private long readSLEB128(ref ubyte[] buffer) {
	import std.array;
	long val = 0;
	uint shift = 0;
	ubyte b;
	int size = 8 << 3;

	while (true) {
		b = buffer.read!ubyte();
		val |= (b & 0x7f) << shift;
		shift += 7;
		if ((b & 0x80) == 0)
			break;
	}

	if (shift < size && (b & 0x40) != 0) val |= -(1 << shift);
	return val;
}

private enum StandardOpcode : ubyte {
	extendedOp = 0,
	copy = 1,
	advancePC = 2,
	advanceLine = 3,
	setFile = 4,
	setColumn = 5,
	negateStatement = 6,
	setBasicBlock = 7,
	constAddPC = 8,
	fixedAdvancePC = 9,
	setPrologueEnd = 10,
	setEpilogueBegin = 11,
	setISA = 12,
}

private enum ExtendedOpcode : ubyte {
	endSequence = 1,
	setAddress = 2,
	defineFile = 3,
}

private struct Machine {
	ulong address = 0;
	uint operationIndex = 0;
	uint fileIndex = 1;
	uint line = 1;
	uint column = 0;
	bool isStatement;
	bool isBasicBlock = false;
	bool isEndSequence = false;
	bool isPrologueEnd = false;
	bool isEpilogueBegin = false;
	uint isa = 0;
	uint discriminator = 0;
}

struct LineProgram {
	private {
		LineProgramHeader m_header;

		ubyte[] m_standardOpcodeLengths;
		string[] m_files;
		string[] m_dirs;

		AddressInfo[] m_addresses;
	}

	const(AddressInfo)[] addressInfo() const {
		return m_addresses;
	}

	string fileFromIndex(ulong fileIndex) const {
		return m_files[fileIndex - 1];
	}
}

struct AddressInfo {
	ulong line;
	ulong fileIndex;
	ulong address;
}
