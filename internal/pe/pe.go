// Package pe implements a minimal PE32+ (x64) parser used to read the
// export table of a Windows DLL. It only implements what the patcher
// needs: section headers (for RVA -> file offset translation) and the
// export directory (name, RVA, file offset of every exported symbol).
package pe

import (
	"encoding/binary"
	"errors"
	"fmt"
)

// Section is a trimmed-down IMAGE_SECTION_HEADER.
type Section struct {
	Name             string
	VirtualAddress   uint32
	VirtualSize      uint32
	PointerToRawData uint32
	SizeOfRawData    uint32
}

// Export is one entry of the DLL export table.
type Export struct {
	Name       string
	RVA        uint32
	FileOffset uint32
}

// File holds the parsed-enough-to-be-useful parts of a PE image.
type File struct {
	Data     []byte
	Sections []Section
	Exports  []Export
}

// Parse reads the DOS/COFF/Optional headers, the section table and the
// export directory of the PE image held in data. It supports both
// PE32 and PE32+ (x64) optional headers.
func Parse(data []byte) (*File, error) {
	if len(data) < 0x40 || string(data[0:2]) != "MZ" {
		return nil, errors.New("not a valid PE file (missing MZ signature)")
	}

	eLfanew := binary.LittleEndian.Uint32(data[0x3C:0x40])
	if int(eLfanew)+4 > len(data) || string(data[eLfanew:eLfanew+4]) != "PE\x00\x00" {
		return nil, errors.New("not a valid PE file (missing PE\\0\\0 signature)")
	}

	coffOffset := int(eLfanew) + 4
	// IMAGE_FILE_HEADER: Machine(2) NumberOfSections(2) TimeDateStamp(4)
	// PointerToSymbolTable(4) NumberOfSymbols(4) SizeOfOptionalHeader(2) Characteristics(2)
	numSections := binary.LittleEndian.Uint16(data[coffOffset+2 : coffOffset+4])
	sizeOptHeader := binary.LittleEndian.Uint16(data[coffOffset+16 : coffOffset+18])

	optOffset := coffOffset + 20
	magic := binary.LittleEndian.Uint16(data[optOffset : optOffset+2])

	var exportDirOffset int
	switch magic {
	case 0x20B: // PE32+ (64-bit)
		exportDirOffset = optOffset + 112
	case 0x10B: // PE32
		exportDirOffset = optOffset + 96
	default:
		return nil, fmt.Errorf("unsupported PE OptionalHeader magic: 0x%X", magic)
	}

	exportRVA := binary.LittleEndian.Uint32(data[exportDirOffset : exportDirOffset+4])
	exportSize := binary.LittleEndian.Uint32(data[exportDirOffset+4 : exportDirOffset+8])

	secTableOffset := optOffset + int(sizeOptHeader)
	sections := make([]Section, 0, numSections)
	for i := 0; i < int(numSections); i++ {
		off := secTableOffset + i*40
		name := string(data[off : off+8])
		// Trim trailing NUL bytes from the fixed-size section name.
		for j := 0; j < len(name); j++ {
			if name[j] == 0 {
				name = name[:j]
				break
			}
		}
		sec := Section{
			Name:             name,
			VirtualSize:      binary.LittleEndian.Uint32(data[off+8 : off+12]),
			VirtualAddress:   binary.LittleEndian.Uint32(data[off+12 : off+16]),
			SizeOfRawData:    binary.LittleEndian.Uint32(data[off+16 : off+20]),
			PointerToRawData: binary.LittleEndian.Uint32(data[off+20 : off+24]),
		}
		sections = append(sections, sec)
	}

	f := &File{Data: data, Sections: sections}

	rvaToOffset := func(rva uint32) (uint32, error) {
		for _, s := range sections {
			span := s.VirtualSize
			if s.SizeOfRawData > span {
				span = s.SizeOfRawData
			}
			if rva >= s.VirtualAddress && rva < s.VirtualAddress+span {
				return s.PointerToRawData + (rva - s.VirtualAddress), nil
			}
		}
		return 0, fmt.Errorf("could not translate RVA 0x%X to a file offset", rva)
	}

	if exportRVA != 0 && exportSize != 0 {
		expOff, err := rvaToOffset(exportRVA)
		if err != nil {
			return nil, err
		}
		// IMAGE_EXPORT_DIRECTORY (40 bytes):
		// Characteristics, TimeDateStamp, MajorVersion, MinorVersion, Name, Base,
		// NumberOfFunctions, NumberOfNames, AddressOfFunctions, AddressOfNames, AddressOfNameOrdinals
		numFuncs := binary.LittleEndian.Uint32(data[expOff+20 : expOff+24])
		_ = numFuncs
		numNames := binary.LittleEndian.Uint32(data[expOff+24 : expOff+28])
		addrFuncsRVA := binary.LittleEndian.Uint32(data[expOff+28 : expOff+32])
		addrNamesRVA := binary.LittleEndian.Uint32(data[expOff+32 : expOff+36])
		addrOrdsRVA := binary.LittleEndian.Uint32(data[expOff+36 : expOff+40])

		funcsOff, err := rvaToOffset(addrFuncsRVA)
		if err != nil {
			return nil, err
		}
		namesOff, err := rvaToOffset(addrNamesRVA)
		if err != nil {
			return nil, err
		}
		ordsOff, err := rvaToOffset(addrOrdsRVA)
		if err != nil {
			return nil, err
		}

		for i := uint32(0); i < numNames; i++ {
			nameRVA := binary.LittleEndian.Uint32(data[namesOff+i*4 : namesOff+i*4+4])
			ordinalIndex := binary.LittleEndian.Uint16(data[ordsOff+i*2 : ordsOff+i*2+2])
			funcRVA := binary.LittleEndian.Uint32(data[funcsOff+uint32(ordinalIndex)*4 : funcsOff+uint32(ordinalIndex)*4+4])

			// Skip forwarded exports (RVA points back inside the export directory).
			if funcRVA >= exportRVA && funcRVA < exportRVA+exportSize {
				continue
			}

			namePos, err := rvaToOffset(nameRVA)
			if err != nil {
				return nil, err
			}
			end := namePos
			for end < uint32(len(data)) && data[end] != 0 {
				end++
			}
			name := string(data[namePos:end])

			funcFileOff, err := rvaToOffset(funcRVA)
			if err != nil {
				return nil, err
			}

			f.Exports = append(f.Exports, Export{Name: name, RVA: funcRVA, FileOffset: funcFileOff})
		}
	}

	return f, nil
}
