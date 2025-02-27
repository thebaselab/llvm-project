//===- yaml2obj - Convert YAML to a binary object file --------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This program takes a YAML description of an object file and outputs the
// binary equivalent.
//
// This is used for writing tests that require binary files.
//
//===----------------------------------------------------------------------===//

#include "llvm/ObjectYAML/yaml2obj.h"
#include "llvm/ADT/StringExtras.h"
#include "llvm/ObjectYAML/ObjectYAML.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/InitLLVM.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/ToolOutputFile.h"
#include "llvm/Support/WithColor.h"
#include "llvm/Support/YAMLTraits.h"
#include "llvm/Support/raw_ostream.h"
#include <system_error>

#ifdef __APPLE__
#include <TargetConditionals.h>
#if (TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR)
#include "ios_error.h"
#undef exit
#define exit(a) { llvm_shutdown(); ios_exit(a); }
#endif
#endif

using namespace llvm;

namespace {
cl::OptionCategory Cat("yaml2obj Options");

cl::opt<std::string> Input(cl::Positional, cl::desc("<input file>"),
                           cl::init("-"), cl::cat(Cat));

cl::list<std::string>
    D("D", cl::Prefix,
      cl::desc("Defined the specified macros to their specified "
               "definition. The syntax is <macro>=<definition>"),
      cl::cat(Cat));

cl::opt<unsigned>
    DocNum("docnum", cl::init(1),
           cl::desc("Read specified document from input (default = 1)"),
           cl::cat(Cat));

static cl::opt<uint64_t> MaxSize(
    "max-size", cl::init(10 * 1024 * 1024),
    cl::desc(
        "Sets the maximum allowed output size (0 means no limit) [ELF only]"),
    cl::cat(Cat));

cl::opt<std::string> OutputFilename("o", cl::desc("Output filename"),
                                    cl::value_desc("filename"), cl::init("-"),
                                    cl::Prefix, cl::cat(Cat));
} // namespace

static Optional<std::string> preprocess(StringRef Buf,
                                        yaml::ErrorHandler ErrHandler) {
  DenseMap<StringRef, StringRef> Defines;
  for (StringRef Define : D) {
    StringRef Macro, Definition;
    std::tie(Macro, Definition) = Define.split('=');
    if (!Define.count('=') || Macro.empty()) {
      ErrHandler("invalid syntax for -D: " + Define);
      return {};
    }
    if (!Defines.try_emplace(Macro, Definition).second) {
      ErrHandler("'" + Macro + "'" + " redefined");
      return {};
    }
  }

  std::string Preprocessed;
  while (!Buf.empty()) {
    if (Buf.startswith("[[")) {
      size_t I = Buf.find_first_of("[]", 2);
      if (Buf.substr(I).startswith("]]")) {
        StringRef MacroExpr = Buf.substr(2, I - 2);
        StringRef Macro;
        StringRef Default;
        std::tie(Macro, Default) = MacroExpr.split('=');

        // When the -D option is requested, we use the provided value.
        // Otherwise we use a default macro value if present.
        auto It = Defines.find(Macro);
        Optional<StringRef> Value;
        if (It != Defines.end())
          Value = It->second;
        else if (!Default.empty() || MacroExpr.endswith("="))
          Value = Default;

        if (Value) {
          Preprocessed += *Value;
          Buf = Buf.substr(I + 2);
          continue;
        }
      }
    }

    Preprocessed += Buf[0];
    Buf = Buf.substr(1);
  }

  return Preprocessed;
}

int main(int argc, char **argv) {
  InitLLVM X(argc, argv);
  cl::HideUnrelatedOptions(Cat);
  cl::ParseCommandLineOptions(
      argc, argv, "Create an object file from a YAML description", nullptr,
      nullptr, /*LongOptionsUseDoubleDash=*/true);

  auto ErrHandler = [](const Twine &Msg) {
    WithColor::error(errs(), "yaml2obj") << Msg << "\n";
  };

  std::error_code EC;
  std::unique_ptr<ToolOutputFile> Out(
      new ToolOutputFile(OutputFilename, EC, sys::fs::OF_None));
  if (EC) {
    ErrHandler("failed to open '" + OutputFilename + "': " + EC.message());
    return 1;
  }

  ErrorOr<std::unique_ptr<MemoryBuffer>> Buf =
      MemoryBuffer::getFileOrSTDIN(Input);
  if (!Buf)
    return 1;

  Optional<std::string> Buffer = preprocess(Buf.get()->getBuffer(), ErrHandler);
  if (!Buffer)
    return 1;
  yaml::Input YIn(*Buffer);

  if (!convertYAML(YIn, Out->os(), ErrHandler, DocNum,
                   MaxSize == 0 ? UINT64_MAX : MaxSize))
    return 1;

  Out->keep();
  Out->os().flush();
  return 0;
}
