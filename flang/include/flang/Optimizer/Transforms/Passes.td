//===-- Passes.td - Transforms pass definition file --------*- tablegen -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This file contains definitions for passes within the Optimizer/Transforms/
// directory.
//
//===----------------------------------------------------------------------===//

#ifndef FLANG_OPTIMIZER_TRANSFORMS_PASSES
#define FLANG_OPTIMIZER_TRANSFORMS_PASSES

include "mlir/Pass/PassBase.td"

def AbstractResultOpt : Pass<"abstract-result-opt", "mlir::FuncOp"> {
  let summary = "Convert fir.array, fir.box and fir.rec function result to "
                "function argument";
  let description = [{
    This pass is required before code gen to the LLVM IR dialect,
    including the pre-cg rewrite pass.
  }];
  let constructor = "::fir::createAbstractResultOptPass()";
  let dependentDialects = [
    "fir::FIROpsDialect", "mlir::StandardOpsDialect"
  ];
  let options = [
    Option<"passResultAsBox", "abstract-result-as-box",
           "bool", /*default=*/"false",
           "Pass fir.array<T> result as fir.box<fir.array<T>> argument instead"
           " of fir.ref<fir.array<T>>.">
  ];
}

def AffineDialectPromotion : FunctionPass<"promote-to-affine"> {
  let summary = "Promotes `fir.{do_loop,if}` to `affine.{for,if}`.";
  let description = [{
    Convert fir operations which satisfy affine constraints to the affine
    dialect.

    `fir.do_loop` will be converted to `affine.for` if the loops inside the body
    can be converted and the indices for memory loads and stores satisfy
    `affine.apply` criteria for symbols and dimensions.

    `fir.if` will be converted to `affine.if` where possible. `affine.if`'s
    condition uses an integer set (==, >=) and an analysis is done to determine
    the fir condition's parent operations to construct the integer set.

    `fir.load` (`fir.store`) will be converted to `affine.load` (`affine.store`)
    where possible. This conversion includes adding a dummy `fir.convert` cast
    to adapt values of type `!fir.ref<!fir.array>` to `memref`. This is done
    because the affine dialect presently only understands the `memref` type.
  }];
  let constructor = "::fir::createPromoteToAffinePass()";
  let dependentDialects = [
    "fir::FIROpsDialect", "mlir::StandardOpsDialect", "mlir::AffineDialect"
  ];
}

def AffineDialectDemotion : FunctionPass<"demote-affine"> {
  let summary = "Converts `affine.{load,store}` back to fir operations";
  let description = [{
    Affine dialect's default lowering for loads and stores is different from
    fir as it uses the `memref` type. The `memref` type is not compatible with
    the Fortran runtime. Therefore, conversion of memory operations back to
    `fir.load` and `fir.store` with `!fir.ref<?>` types is required.
  }];
  let constructor = "::fir::createAffineDemotionPass()";
  let dependentDialects = [
    "fir::FIROpsDialect", "mlir::StandardOpsDialect", "mlir::AffineDialect"
  ];
}

def ArrayValueCopy : FunctionPass<"array-value-copy"> {
  let summary = "Convert array value operations to memory operations.";
  let description = [{
    Transform the set of array value primitives to a memory-based array
    representation.

    The Ops `array_load`, `array_store`, `array_fetch`, and `array_update` are
    used to manage abstract aggregate array values. A simple analysis is done
    to determine if there are potential dependences between these operations.
    If not, these array operations can be lowered to work directly on the memory
    representation. If there is a potential conflict, a temporary is created
    along with appropriate copy-in/copy-out operations. Here, a more refined
    analysis might be deployed, such as using the affine framework.

    This pass is required before code gen to the LLVM IR dialect.
  }];
  let constructor = "::fir::createArrayValueCopyPass()";
}

def CharacterConversion : Pass<"character-conversion"> {
  let summary = "Convert CHARACTER entities with different KINDs";
  let description = [{
    Translates entities of one CHARACTER KIND to another.

    By default the translation is to naively zero-extend or truncate a code
    point to fit the destination size.
  }];
  let constructor = "::fir::createCharacterConversionPass()";
  let dependentDialects = [ "fir::FIROpsDialect" ];
  let options = [
    Option<"useRuntimeCalls", "use-runtime-calls",
           "std::string", /*default=*/"std::string{}",
           "Generate runtime calls to a named set of conversion routines. "
           "By default, the conversions may produce unexpected results.">
  ];
}

def CFGConversion : FunctionPass<"cfg-conversion"> {
  let summary = "Convert FIR structured control flow ops to CFG ops.";
  let description = [{
    Transform the `fir.do_loop`, `fir.if`, and `fir.iterate_while` ops into
    plain old test and branch operations. Removing the high-level control
    structures can enable other optimizations.

    This pass is required before code gen to the LLVM IR dialect.
  }];
  let constructor = "::fir::createFirToCfgPass()";
  let dependentDialects = [
    "fir::FIROpsDialect", "mlir::StandardOpsDialect"
  ];
  let options = [
    Option<"forceLoopToExecuteOnce", "always-execute-loop-body", "bool",
           /*default=*/"false",
           "force the body of a loop to execute at least once">
  ];
}

def ExternalNameConversion : Pass<"external-name-interop", "mlir::ModuleOp"> {
  let summary = "Convert name for external interoperability";
  let description = [{
    Demangle FIR internal name and mangle them for external interoperability.
  }];
  let constructor = "::fir::createExternalNameConversionPass()";
}

def MemRefDataFlowOpt : FunctionPass<"fir-memref-dataflow-opt"> {
  let summary =
    "Perform store/load forwarding and potentially removing dead stores.";
  let description = [{
    This pass performs store to load forwarding to eliminate memory accesses and
    potentially the entire allocation if all the accesses are forwarded.
  }];
  let constructor = "::fir::createMemDataFlowOptPass()";
  let dependentDialects = [
    "fir::FIROpsDialect", "mlir::StandardOpsDialect"
  ];
}

def MemoryAllocationOpt : Pass<"memory-allocation-opt", "mlir::FuncOp"> {
  let summary = "Convert stack to heap allocations and vice versa.";
  let description = [{
    Convert stack allocations to heap allocations and vice versa based on
    estimated size, lifetime, usage patterns, the call tree, etc.
  }];
  let dependentDialects = [ "fir::FIROpsDialect" ];
  let options = [
    Option<"dynamicArrayOnHeap", "dynamic-array-on-heap",
           "bool", /*default=*/"false",
           "Allocate all arrays with runtime determined size on heap.">,
    Option<"maxStackArraySize", "maximum-array-alloc-size",
           "std::size_t", /*default=*/"~static_cast<std::size_t>(0)",
           "Set maximum number of elements of an array allocated on the stack.">
  ];
  let constructor = "::fir::createMemoryAllocationPass()";
}

#endif // FLANG_OPTIMIZER_TRANSFORMS_PASSES
