/*
 * Copyright (c) 2015 Andrew Kelley
 *
 * This file is part of zig, which is MIT licensed.
 * See http://opensource.org/licenses/MIT
 */


/*
 * The point of this file is to contain all the LLVM C++ API interaction so that:
 * 1. The compile time of other files is kept under control.
 * 2. Provide a C interface to the LLVM functions we need for self-hosting purposes.
 * 3. Prevent C++ from infecting the rest of the project.
 */

#include "zig_llvm.h"

#if __GNUC__ >= 9
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Winit-list-lifetime"
#endif

#include <llvm/Analysis/TargetLibraryInfo.h>
#include <llvm/Analysis/TargetTransformInfo.h>
#include <llvm/IR/DIBuilder.h>
#include <llvm/IR/DiagnosticInfo.h>
#include <llvm/IR/IRBuilder.h>
#include <llvm/IR/InlineAsm.h>
#include <llvm/IR/Instructions.h>
#include <llvm/IR/LegacyPassManager.h>
#include <llvm/IR/Module.h>
#include <llvm/IR/Verifier.h>
#include <llvm/InitializePasses.h>
#include <llvm/MC/SubtargetFeature.h>
#include <llvm/Object/Archive.h>
#include <llvm/Object/ArchiveWriter.h>
#include <llvm/Object/COFF.h>
#include <llvm/Object/COFFImportFile.h>
#include <llvm/Object/COFFModuleDefinition.h>
#include <llvm/PassRegistry.h>
#include <llvm/Support/FileSystem.h>
#include <llvm/Support/TargetParser.h>
#include <llvm/Support/Timer.h>
#include <llvm/Support/raw_ostream.h>
#include <llvm/Support/TargetRegistry.h>
#include <llvm/Target/TargetMachine.h>
#include <llvm/Target/CodeGenCWrappers.h>
#include <llvm/Transforms/IPO.h>
#include <llvm/Transforms/IPO/AlwaysInliner.h>
#include <llvm/Transforms/IPO/PassManagerBuilder.h>
#include <llvm/Transforms/Scalar.h>
#include <llvm/Transforms/Utils.h>

#include <lld/Common/Driver.h>

#if __GNUC__ >= 9
#pragma GCC diagnostic pop
#endif

#include <new>

#include <stdlib.h>

using namespace llvm;

void ZigLLVMInitializeLoopStrengthReducePass(LLVMPassRegistryRef R) {
    initializeLoopStrengthReducePass(*unwrap(R));
}

void ZigLLVMInitializeLowerIntrinsicsPass(LLVMPassRegistryRef R) {
    initializeLowerIntrinsicsPass(*unwrap(R));
}

char *ZigLLVMGetHostCPUName(void) {
    return strdup((const char *)sys::getHostCPUName().bytes_begin());
}

char *ZigLLVMGetNativeFeatures(void) {
    SubtargetFeatures features;

    StringMap<bool> host_features;
    if (sys::getHostCPUFeatures(host_features)) {
        for (auto &F : host_features)
            features.AddFeature(F.first(), F.second);
    }

    return strdup((const char *)StringRef(features.getString()).bytes_begin());
}

static void addDiscriminatorsPass(const PassManagerBuilder &Builder, legacy::PassManagerBase &PM) {
    PM.add(createAddDiscriminatorsPass());
}

#ifndef NDEBUG
static const bool assertions_on = true;
#else
static const bool assertions_on = false;
#endif

LLVMTargetMachineRef ZigLLVMCreateTargetMachine(LLVMTargetRef T, const char *Triple,
    const char *CPU, const char *Features, LLVMCodeGenOptLevel Level, LLVMRelocMode Reloc,
    LLVMCodeModel CodeModel, bool function_sections)
{
    Optional<Reloc::Model> RM;
    switch (Reloc){
        case LLVMRelocStatic:
            RM = Reloc::Static;
            break;
        case LLVMRelocPIC:
            RM = Reloc::PIC_;
            break;
        case LLVMRelocDynamicNoPic:
            RM = Reloc::DynamicNoPIC;
            break;
        case LLVMRelocROPI:
            RM = Reloc::ROPI;
            break;
        case LLVMRelocRWPI:
            RM = Reloc::RWPI;
            break;
        case LLVMRelocROPI_RWPI:
            RM = Reloc::ROPI_RWPI;
            break;
        default:
            break;
    }

    bool JIT;
    Optional<CodeModel::Model> CM = unwrap(CodeModel, JIT);

    CodeGenOpt::Level OL;
    switch (Level) {
        case LLVMCodeGenLevelNone:
            OL = CodeGenOpt::None;
            break;
        case LLVMCodeGenLevelLess:
            OL = CodeGenOpt::Less;
            break;
        case LLVMCodeGenLevelAggressive:
            OL = CodeGenOpt::Aggressive;
            break;
        default:
            OL = CodeGenOpt::Default;
            break;
    }

    TargetOptions opt;
    opt.FunctionSections = function_sections;

    TargetMachine *TM = reinterpret_cast<Target*>(T)->createTargetMachine(Triple, CPU, Features, opt, RM, CM,
            OL, JIT);
    return reinterpret_cast<LLVMTargetMachineRef>(TM);
}

unsigned ZigLLVMDataLayoutGetStackAlignment(LLVMTargetDataRef TD) {
    return unwrap(TD)->getStackAlignment();
}

unsigned ZigLLVMDataLayoutGetProgramAddressSpace(LLVMTargetDataRef TD) {
    return unwrap(TD)->getProgramAddressSpace();
}

bool ZigLLVMTargetMachineEmitToFile(LLVMTargetMachineRef targ_machine_ref, LLVMModuleRef module_ref,
        const char *filename, ZigLLVM_EmitOutputType output_type, char **error_message, bool is_debug,
        bool is_small, bool time_report)
{
    TimePassesIsEnabled = time_report;

    std::error_code EC;
    raw_fd_ostream dest(filename, EC, sys::fs::F_None);
    if (EC) {
        *error_message = strdup((const char *)StringRef(EC.message()).bytes_begin());
        return true;
    }
    TargetMachine* target_machine = reinterpret_cast<TargetMachine*>(targ_machine_ref);
    target_machine->setO0WantsFastISel(true);

    Module* module = unwrap(module_ref);

    PassManagerBuilder *PMBuilder = new(std::nothrow) PassManagerBuilder();
    if (PMBuilder == nullptr) {
        *error_message = strdup("memory allocation failure");
        return true;
    }
    PMBuilder->OptLevel = target_machine->getOptLevel();
    PMBuilder->SizeLevel = is_small ? 2 : 0;

    PMBuilder->DisableTailCalls = is_debug;
    PMBuilder->DisableUnrollLoops = is_debug;
    PMBuilder->SLPVectorize = !is_debug;
    PMBuilder->LoopVectorize = !is_debug;
    PMBuilder->RerollLoops = !is_debug;
    // Leaving NewGVN as default (off) because when on it caused issue #673
    //PMBuilder->NewGVN = !is_debug;
    PMBuilder->DisableGVNLoadPRE = is_debug;
    PMBuilder->VerifyInput = assertions_on;
    PMBuilder->VerifyOutput = assertions_on;
    PMBuilder->MergeFunctions = !is_debug;
    PMBuilder->PrepareForLTO = false;
    PMBuilder->PrepareForThinLTO = false;
    PMBuilder->PerformThinLTO = false;

    TargetLibraryInfoImpl tlii(Triple(module->getTargetTriple()));
    PMBuilder->LibraryInfo = &tlii;

    if (is_debug) {
        PMBuilder->Inliner = createAlwaysInlinerLegacyPass(false);
    } else {
        target_machine->adjustPassManager(*PMBuilder);

        PMBuilder->addExtension(PassManagerBuilder::EP_EarlyAsPossible, addDiscriminatorsPass);
        PMBuilder->Inliner = createFunctionInliningPass(PMBuilder->OptLevel, PMBuilder->SizeLevel, false);
    }

    // Set up the per-function pass manager.
    legacy::FunctionPassManager FPM = legacy::FunctionPassManager(module);
    auto tliwp = new(std::nothrow) TargetLibraryInfoWrapperPass(tlii);
    FPM.add(tliwp);
    FPM.add(createTargetTransformInfoWrapperPass(target_machine->getTargetIRAnalysis()));
    if (assertions_on) {
        FPM.add(createVerifierPass());
    }
    PMBuilder->populateFunctionPassManager(FPM);

    // Set up the per-module pass manager.
    legacy::PassManager MPM;
    MPM.add(createTargetTransformInfoWrapperPass(target_machine->getTargetIRAnalysis()));
    PMBuilder->populateModulePassManager(MPM);

    // Set output pass.
    TargetMachine::CodeGenFileType ft;
    if (output_type != ZigLLVM_EmitLLVMIr) {
        switch (output_type) {
            case ZigLLVM_EmitAssembly:
                ft = TargetMachine::CGFT_AssemblyFile;
                break;
            case ZigLLVM_EmitBinary:
                ft = TargetMachine::CGFT_ObjectFile;
                break;
            default:
                abort();
        }

        if (target_machine->addPassesToEmitFile(MPM, dest, nullptr, ft)) {
            *error_message = strdup("TargetMachine can't emit a file of this type");
            return true;
        }
    }

    // run per function optimization passes
    FPM.doInitialization();
    for (Function &F : *module)
      if (!F.isDeclaration())
        FPM.run(F);
    FPM.doFinalization();

    MPM.run(*module);

    if (output_type == ZigLLVM_EmitLLVMIr) {
        if (LLVMPrintModuleToFile(module_ref, filename, error_message)) {
            return true;
        }
    }

    if (time_report) {
        TimerGroup::printAll(errs());
    }
    return false;
}

ZIG_EXTERN_C LLVMTypeRef ZigLLVMTokenTypeInContext(LLVMContextRef context_ref) {
  return wrap(Type::getTokenTy(*unwrap(context_ref)));
}

LLVMValueRef ZigLLVMBuildCall(LLVMBuilderRef B, LLVMValueRef Fn, LLVMValueRef *Args,
        unsigned NumArgs, unsigned CC, ZigLLVM_CallAttr attr, const char *Name)
{
    CallInst *call_inst = CallInst::Create(unwrap(Fn), makeArrayRef(unwrap(Args), NumArgs), Name);
    call_inst->setCallingConv(CC);
    switch (attr) {
        case ZigLLVM_CallAttrAuto:
            break;
        case ZigLLVM_CallAttrNeverTail:
            call_inst->setTailCallKind(CallInst::TCK_NoTail);
            break;
        case ZigLLVM_CallAttrNeverInline:
            call_inst->addAttribute(AttributeList::FunctionIndex, Attribute::NoInline);
            break;
        case ZigLLVM_CallAttrAlwaysTail:
            call_inst->setTailCallKind(CallInst::TCK_MustTail);
            break;
        case ZigLLVM_CallAttrAlwaysInline:
            call_inst->addAttribute(AttributeList::FunctionIndex, Attribute::AlwaysInline);
            break;
    }
    return wrap(unwrap(B)->Insert(call_inst));
}

LLVMValueRef ZigLLVMBuildMemCpy(LLVMBuilderRef B, LLVMValueRef Dst, unsigned DstAlign,
        LLVMValueRef Src, unsigned SrcAlign, LLVMValueRef Size, bool isVolatile)
{
    CallInst *call_inst = unwrap(B)->CreateMemCpy(unwrap(Dst), DstAlign, unwrap(Src), SrcAlign, unwrap(Size), isVolatile);
    return wrap(call_inst);
}

LLVMValueRef ZigLLVMBuildMemSet(LLVMBuilderRef B, LLVMValueRef Ptr, LLVMValueRef Val, LLVMValueRef Size,
        unsigned Align, bool isVolatile)
{
    CallInst *call_inst = unwrap(B)->CreateMemSet(unwrap(Ptr), unwrap(Val), unwrap(Size), Align, isVolatile);
    return wrap(call_inst);
}

void ZigLLVMFnSetSubprogram(LLVMValueRef fn, ZigLLVMDISubprogram *subprogram) {
    assert( isa<Function>(unwrap(fn)) );
    Function *unwrapped_function = reinterpret_cast<Function*>(unwrap(fn));
    unwrapped_function->setSubprogram(reinterpret_cast<DISubprogram*>(subprogram));
}


ZigLLVMDIType *ZigLLVMCreateDebugPointerType(ZigLLVMDIBuilder *dibuilder, ZigLLVMDIType *pointee_type,
        uint64_t size_in_bits, uint64_t align_in_bits, const char *name)
{
    DIType *di_type = reinterpret_cast<DIBuilder*>(dibuilder)->createPointerType(
            reinterpret_cast<DIType*>(pointee_type), size_in_bits, align_in_bits, Optional<unsigned>(), name);
    return reinterpret_cast<ZigLLVMDIType*>(di_type);
}

ZigLLVMDIType *ZigLLVMCreateDebugBasicType(ZigLLVMDIBuilder *dibuilder, const char *name,
        uint64_t size_in_bits, unsigned encoding)
{
    DIType *di_type = reinterpret_cast<DIBuilder*>(dibuilder)->createBasicType(
            name, size_in_bits, encoding);
    return reinterpret_cast<ZigLLVMDIType*>(di_type);
}

struct ZigLLVMDIType *ZigLLVMDIBuilderCreateVectorType(struct ZigLLVMDIBuilder *dibuilder,
        uint64_t SizeInBits, uint32_t AlignInBits, struct ZigLLVMDIType *Ty, uint32_t elem_count)
{
    SmallVector<Metadata *, 1> subrange;
    subrange.push_back(reinterpret_cast<DIBuilder*>(dibuilder)->getOrCreateSubrange(0, elem_count));
    DIType *di_type = reinterpret_cast<DIBuilder*>(dibuilder)->createVectorType(
            SizeInBits,
            AlignInBits,
            reinterpret_cast<DIType*>(Ty),
            reinterpret_cast<DIBuilder*>(dibuilder)->getOrCreateArray(subrange));
    return reinterpret_cast<ZigLLVMDIType*>(di_type);
}

ZigLLVMDIType *ZigLLVMCreateDebugArrayType(ZigLLVMDIBuilder *dibuilder, uint64_t size_in_bits,
        uint64_t align_in_bits, ZigLLVMDIType *elem_type, int elem_count)
{
    SmallVector<Metadata *, 1> subrange;
    subrange.push_back(reinterpret_cast<DIBuilder*>(dibuilder)->getOrCreateSubrange(0, elem_count));
    DIType *di_type = reinterpret_cast<DIBuilder*>(dibuilder)->createArrayType(
            size_in_bits, align_in_bits,
            reinterpret_cast<DIType*>(elem_type),
            reinterpret_cast<DIBuilder*>(dibuilder)->getOrCreateArray(subrange));
    return reinterpret_cast<ZigLLVMDIType*>(di_type);
}

ZigLLVMDIEnumerator *ZigLLVMCreateDebugEnumerator(ZigLLVMDIBuilder *dibuilder, const char *name, int64_t val) {
    DIEnumerator *di_enumerator = reinterpret_cast<DIBuilder*>(dibuilder)->createEnumerator(name, val);
    return reinterpret_cast<ZigLLVMDIEnumerator*>(di_enumerator);
}

ZigLLVMDIType *ZigLLVMCreateDebugEnumerationType(ZigLLVMDIBuilder *dibuilder, ZigLLVMDIScope *scope,
        const char *name, ZigLLVMDIFile *file, unsigned line_number, uint64_t size_in_bits,
        uint64_t align_in_bits, ZigLLVMDIEnumerator **enumerator_array, int enumerator_array_len,
        ZigLLVMDIType *underlying_type, const char *unique_id)
{
    SmallVector<Metadata *, 8> fields;
    for (int i = 0; i < enumerator_array_len; i += 1) {
        DIEnumerator *dienumerator = reinterpret_cast<DIEnumerator*>(enumerator_array[i]);
        fields.push_back(dienumerator);
    }
    DIType *di_type = reinterpret_cast<DIBuilder*>(dibuilder)->createEnumerationType(
            reinterpret_cast<DIScope*>(scope),
            name,
            reinterpret_cast<DIFile*>(file),
            line_number, size_in_bits, align_in_bits,
            reinterpret_cast<DIBuilder*>(dibuilder)->getOrCreateArray(fields),
            reinterpret_cast<DIType*>(underlying_type),
            unique_id);
    return reinterpret_cast<ZigLLVMDIType*>(di_type);
}

ZigLLVMDIType *ZigLLVMCreateDebugMemberType(ZigLLVMDIBuilder *dibuilder, ZigLLVMDIScope *scope,
        const char *name, ZigLLVMDIFile *file, unsigned line, uint64_t size_in_bits,
        uint64_t align_in_bits, uint64_t offset_in_bits, unsigned flags, ZigLLVMDIType *type)
{
    DIType *di_type = reinterpret_cast<DIBuilder*>(dibuilder)->createMemberType(
            reinterpret_cast<DIScope*>(scope),
            name,
            reinterpret_cast<DIFile*>(file),
            line, size_in_bits, align_in_bits, offset_in_bits,
            static_cast<DINode::DIFlags>(flags),
            reinterpret_cast<DIType*>(type));
    return reinterpret_cast<ZigLLVMDIType*>(di_type);
}

ZigLLVMDIType *ZigLLVMCreateDebugUnionType(ZigLLVMDIBuilder *dibuilder, ZigLLVMDIScope *scope,
        const char *name, ZigLLVMDIFile *file, unsigned line_number, uint64_t size_in_bits,
        uint64_t align_in_bits, unsigned flags, ZigLLVMDIType **types_array, int types_array_len,
        unsigned run_time_lang, const char *unique_id)
{
    SmallVector<Metadata *, 8> fields;
    for (int i = 0; i < types_array_len; i += 1) {
        DIType *ditype = reinterpret_cast<DIType*>(types_array[i]);
        fields.push_back(ditype);
    }
    DIType *di_type = reinterpret_cast<DIBuilder*>(dibuilder)->createUnionType(
            reinterpret_cast<DIScope*>(scope),
            name,
            reinterpret_cast<DIFile*>(file),
            line_number, size_in_bits, align_in_bits,
            static_cast<DINode::DIFlags>(flags),
            reinterpret_cast<DIBuilder*>(dibuilder)->getOrCreateArray(fields),
            run_time_lang, unique_id);
    return reinterpret_cast<ZigLLVMDIType*>(di_type);
}

ZigLLVMDIType *ZigLLVMCreateDebugStructType(ZigLLVMDIBuilder *dibuilder, ZigLLVMDIScope *scope,
        const char *name, ZigLLVMDIFile *file, unsigned line_number, uint64_t size_in_bits,
        uint64_t align_in_bits, unsigned flags, ZigLLVMDIType *derived_from,
        ZigLLVMDIType **types_array, int types_array_len, unsigned run_time_lang, ZigLLVMDIType *vtable_holder,
        const char *unique_id)
{
    SmallVector<Metadata *, 8> fields;
    for (int i = 0; i < types_array_len; i += 1) {
        DIType *ditype = reinterpret_cast<DIType*>(types_array[i]);
        fields.push_back(ditype);
    }
    DIType *di_type = reinterpret_cast<DIBuilder*>(dibuilder)->createStructType(
            reinterpret_cast<DIScope*>(scope),
            name,
            reinterpret_cast<DIFile*>(file),
            line_number, size_in_bits, align_in_bits,
            static_cast<DINode::DIFlags>(flags),
            reinterpret_cast<DIType*>(derived_from),
            reinterpret_cast<DIBuilder*>(dibuilder)->getOrCreateArray(fields),
            run_time_lang,
            reinterpret_cast<DIType*>(vtable_holder),
            unique_id);
    return reinterpret_cast<ZigLLVMDIType*>(di_type);
}

ZigLLVMDIType *ZigLLVMCreateReplaceableCompositeType(ZigLLVMDIBuilder *dibuilder, unsigned tag,
        const char *name, ZigLLVMDIScope *scope, ZigLLVMDIFile *file, unsigned line)
{
    DIType *di_type = reinterpret_cast<DIBuilder*>(dibuilder)->createReplaceableCompositeType(
            tag, name,
            reinterpret_cast<DIScope*>(scope),
            reinterpret_cast<DIFile*>(file),
            line);
    return reinterpret_cast<ZigLLVMDIType*>(di_type);
}

ZigLLVMDIType *ZigLLVMCreateDebugForwardDeclType(ZigLLVMDIBuilder *dibuilder, unsigned tag,
        const char *name, ZigLLVMDIScope *scope, ZigLLVMDIFile *file, unsigned line)
{
    DIType *di_type = reinterpret_cast<DIBuilder*>(dibuilder)->createForwardDecl(
            tag, name,
            reinterpret_cast<DIScope*>(scope),
            reinterpret_cast<DIFile*>(file),
            line);
    return reinterpret_cast<ZigLLVMDIType*>(di_type);
}

void ZigLLVMReplaceTemporary(ZigLLVMDIBuilder *dibuilder, ZigLLVMDIType *type,
        ZigLLVMDIType *replacement)
{
    reinterpret_cast<DIBuilder*>(dibuilder)->replaceTemporary(
            TempDIType(reinterpret_cast<DIType*>(type)),
            reinterpret_cast<DIType*>(replacement));
}

void ZigLLVMReplaceDebugArrays(ZigLLVMDIBuilder *dibuilder, ZigLLVMDIType *type,
        ZigLLVMDIType **types_array, int types_array_len)
{
    SmallVector<Metadata *, 8> fields;
    for (int i = 0; i < types_array_len; i += 1) {
        DIType *ditype = reinterpret_cast<DIType*>(types_array[i]);
        fields.push_back(ditype);
    }
    DICompositeType *composite_type = (DICompositeType*)reinterpret_cast<DIType*>(type);
    reinterpret_cast<DIBuilder*>(dibuilder)->replaceArrays(
            composite_type,
            reinterpret_cast<DIBuilder*>(dibuilder)->getOrCreateArray(fields));
}

ZigLLVMDIType *ZigLLVMCreateSubroutineType(ZigLLVMDIBuilder *dibuilder_wrapped,
        ZigLLVMDIType **types_array, int types_array_len, unsigned flags)
{
    SmallVector<Metadata *, 8> types;
    for (int i = 0; i < types_array_len; i += 1) {
        DIType *ditype = reinterpret_cast<DIType*>(types_array[i]);
        types.push_back(ditype);
    }
    DIBuilder *dibuilder = reinterpret_cast<DIBuilder*>(dibuilder_wrapped);
    DISubroutineType *subroutine_type = dibuilder->createSubroutineType(
            dibuilder->getOrCreateTypeArray(types),
            static_cast<DINode::DIFlags>(flags));
    DIType *ditype = subroutine_type;
    return reinterpret_cast<ZigLLVMDIType*>(ditype);
}

unsigned ZigLLVMEncoding_DW_ATE_unsigned(void) {
    return dwarf::DW_ATE_unsigned;
}

unsigned ZigLLVMEncoding_DW_ATE_signed(void) {
    return dwarf::DW_ATE_signed;
}

unsigned ZigLLVMEncoding_DW_ATE_float(void) {
    return dwarf::DW_ATE_float;
}

unsigned ZigLLVMEncoding_DW_ATE_boolean(void) {
    return dwarf::DW_ATE_boolean;
}

unsigned ZigLLVMEncoding_DW_ATE_unsigned_char(void) {
    return dwarf::DW_ATE_unsigned_char;
}

unsigned ZigLLVMEncoding_DW_ATE_signed_char(void) {
    return dwarf::DW_ATE_signed_char;
}

unsigned ZigLLVMLang_DW_LANG_C99(void) {
    return dwarf::DW_LANG_C99;
}

unsigned ZigLLVMTag_DW_variable(void) {
    return dwarf::DW_TAG_variable;
}

unsigned ZigLLVMTag_DW_structure_type(void) {
    return dwarf::DW_TAG_structure_type;
}

unsigned ZigLLVMTag_DW_enumeration_type(void) {
    return dwarf::DW_TAG_enumeration_type;
}

unsigned ZigLLVMTag_DW_union_type(void) {
    return dwarf::DW_TAG_union_type;
}

ZigLLVMDIBuilder *ZigLLVMCreateDIBuilder(LLVMModuleRef module, bool allow_unresolved) {
    DIBuilder *di_builder = new(std::nothrow) DIBuilder(*unwrap(module), allow_unresolved);
    if (di_builder == nullptr)
        return nullptr;
    return reinterpret_cast<ZigLLVMDIBuilder *>(di_builder);
}

void ZigLLVMDisposeDIBuilder(ZigLLVMDIBuilder *dbuilder) {
    DIBuilder *di_builder = reinterpret_cast<DIBuilder *>(dbuilder);
    delete di_builder;
}

void ZigLLVMSetCurrentDebugLocation(LLVMBuilderRef builder, int line, int column, ZigLLVMDIScope *scope) {
    unwrap(builder)->SetCurrentDebugLocation(DebugLoc::get(
                line, column, reinterpret_cast<DIScope*>(scope)));
}

void ZigLLVMClearCurrentDebugLocation(LLVMBuilderRef builder) {
    unwrap(builder)->SetCurrentDebugLocation(DebugLoc());
}


ZigLLVMDILexicalBlock *ZigLLVMCreateLexicalBlock(ZigLLVMDIBuilder *dbuilder, ZigLLVMDIScope *scope,
        ZigLLVMDIFile *file, unsigned line, unsigned col)
{
    DILexicalBlock *result = reinterpret_cast<DIBuilder*>(dbuilder)->createLexicalBlock(
            reinterpret_cast<DIScope*>(scope),
            reinterpret_cast<DIFile*>(file),
            line,
            col);
    return reinterpret_cast<ZigLLVMDILexicalBlock*>(result);
}

ZigLLVMDILocalVariable *ZigLLVMCreateAutoVariable(ZigLLVMDIBuilder *dbuilder,
        ZigLLVMDIScope *scope, const char *name, ZigLLVMDIFile *file, unsigned line_no,
        ZigLLVMDIType *type, bool always_preserve, unsigned flags)
{
    DILocalVariable *result = reinterpret_cast<DIBuilder*>(dbuilder)->createAutoVariable(
            reinterpret_cast<DIScope*>(scope),
            name,
            reinterpret_cast<DIFile*>(file),
            line_no,
            reinterpret_cast<DIType*>(type),
            always_preserve,
            static_cast<DINode::DIFlags>(flags));
    return reinterpret_cast<ZigLLVMDILocalVariable*>(result);
}

ZigLLVMDIGlobalVariable *ZigLLVMCreateGlobalVariable(ZigLLVMDIBuilder *dbuilder,
    ZigLLVMDIScope *scope, const char *name, const char *linkage_name, ZigLLVMDIFile *file,
    unsigned line_no, ZigLLVMDIType *di_type, bool is_local_to_unit)
{
    DIGlobalVariableExpression *result = reinterpret_cast<DIBuilder*>(dbuilder)->createGlobalVariableExpression(
        reinterpret_cast<DIScope*>(scope),
        name,
        linkage_name,
        reinterpret_cast<DIFile*>(file),
        line_no,
        reinterpret_cast<DIType*>(di_type),
        is_local_to_unit);
    return reinterpret_cast<ZigLLVMDIGlobalVariable*>(result);
}

ZigLLVMDILocalVariable *ZigLLVMCreateParameterVariable(ZigLLVMDIBuilder *dbuilder,
        ZigLLVMDIScope *scope, const char *name, ZigLLVMDIFile *file, unsigned line_no,
        ZigLLVMDIType *type, bool always_preserve, unsigned flags, unsigned arg_no)
{
    assert(arg_no != 0);
    DILocalVariable *result = reinterpret_cast<DIBuilder*>(dbuilder)->createParameterVariable(
            reinterpret_cast<DIScope*>(scope),
            name,
            arg_no,
            reinterpret_cast<DIFile*>(file),
            line_no,
            reinterpret_cast<DIType*>(type),
            always_preserve,
            static_cast<DINode::DIFlags>(flags));
    return reinterpret_cast<ZigLLVMDILocalVariable*>(result);
}

ZigLLVMDIScope *ZigLLVMLexicalBlockToScope(ZigLLVMDILexicalBlock *lexical_block) {
    DIScope *scope = reinterpret_cast<DILexicalBlock*>(lexical_block);
    return reinterpret_cast<ZigLLVMDIScope*>(scope);
}

ZigLLVMDIScope *ZigLLVMCompileUnitToScope(ZigLLVMDICompileUnit *compile_unit) {
    DIScope *scope = reinterpret_cast<DICompileUnit*>(compile_unit);
    return reinterpret_cast<ZigLLVMDIScope*>(scope);
}

ZigLLVMDIScope *ZigLLVMFileToScope(ZigLLVMDIFile *difile) {
    DIScope *scope = reinterpret_cast<DIFile*>(difile);
    return reinterpret_cast<ZigLLVMDIScope*>(scope);
}

ZigLLVMDIScope *ZigLLVMSubprogramToScope(ZigLLVMDISubprogram *subprogram) {
    DIScope *scope = reinterpret_cast<DISubprogram*>(subprogram);
    return reinterpret_cast<ZigLLVMDIScope*>(scope);
}

ZigLLVMDIScope *ZigLLVMTypeToScope(ZigLLVMDIType *type) {
    DIScope *scope = reinterpret_cast<DIType*>(type);
    return reinterpret_cast<ZigLLVMDIScope*>(scope);
}

ZigLLVMDICompileUnit *ZigLLVMCreateCompileUnit(ZigLLVMDIBuilder *dibuilder,
        unsigned lang, ZigLLVMDIFile *difile, const char *producer,
        bool is_optimized, const char *flags, unsigned runtime_version, const char *split_name,
        uint64_t dwo_id, bool emit_debug_info)
{
    DICompileUnit *result = reinterpret_cast<DIBuilder*>(dibuilder)->createCompileUnit(
            lang,
            reinterpret_cast<DIFile*>(difile),
            producer, is_optimized, flags, runtime_version, split_name,
            (emit_debug_info ? DICompileUnit::DebugEmissionKind::FullDebug : DICompileUnit::DebugEmissionKind::NoDebug),
            dwo_id);
    return reinterpret_cast<ZigLLVMDICompileUnit*>(result);
}


ZigLLVMDIFile *ZigLLVMCreateFile(ZigLLVMDIBuilder *dibuilder, const char *filename, const char *directory) {
    DIFile *result = reinterpret_cast<DIBuilder*>(dibuilder)->createFile(filename, directory);
    return reinterpret_cast<ZigLLVMDIFile*>(result);
}

ZigLLVMDISubprogram *ZigLLVMCreateFunction(ZigLLVMDIBuilder *dibuilder, ZigLLVMDIScope *scope,
        const char *name, const char *linkage_name, ZigLLVMDIFile *file, unsigned lineno,
        ZigLLVMDIType *fn_di_type, bool is_local_to_unit, bool is_definition, unsigned scope_line,
        unsigned flags, bool is_optimized, ZigLLVMDISubprogram *decl_subprogram)
{
    DISubroutineType *di_sub_type = static_cast<DISubroutineType*>(reinterpret_cast<DIType*>(fn_di_type));
    DISubprogram *result = reinterpret_cast<DIBuilder*>(dibuilder)->createFunction(
            reinterpret_cast<DIScope*>(scope),
            name, linkage_name,
            reinterpret_cast<DIFile*>(file),
            lineno,
            di_sub_type,
            scope_line,
            static_cast<DINode::DIFlags>(flags),
            DISubprogram::toSPFlags(is_local_to_unit, is_definition, is_optimized),
            nullptr,
            reinterpret_cast<DISubprogram *>(decl_subprogram),
            nullptr);
    return reinterpret_cast<ZigLLVMDISubprogram*>(result);
}

void ZigLLVMDIBuilderFinalize(ZigLLVMDIBuilder *dibuilder) {
    reinterpret_cast<DIBuilder*>(dibuilder)->finalize();
}

LLVMValueRef ZigLLVMInsertDeclareAtEnd(ZigLLVMDIBuilder *dibuilder, LLVMValueRef storage,
        ZigLLVMDILocalVariable *var_info, ZigLLVMDILocation *debug_loc, LLVMBasicBlockRef basic_block_ref)
{
    Instruction *result = reinterpret_cast<DIBuilder*>(dibuilder)->insertDeclare(
            unwrap(storage),
            reinterpret_cast<DILocalVariable *>(var_info),
            reinterpret_cast<DIBuilder*>(dibuilder)->createExpression(),
            reinterpret_cast<DILocation*>(debug_loc),
            static_cast<BasicBlock*>(unwrap(basic_block_ref)));
    return wrap(result);
}

LLVMValueRef ZigLLVMInsertDeclare(ZigLLVMDIBuilder *dibuilder, LLVMValueRef storage,
        ZigLLVMDILocalVariable *var_info, ZigLLVMDILocation *debug_loc, LLVMValueRef insert_before_instr)
{
    Instruction *result = reinterpret_cast<DIBuilder*>(dibuilder)->insertDeclare(
            unwrap(storage),
            reinterpret_cast<DILocalVariable *>(var_info),
            reinterpret_cast<DIBuilder*>(dibuilder)->createExpression(),
            reinterpret_cast<DILocation*>(debug_loc),
            static_cast<Instruction*>(unwrap(insert_before_instr)));
    return wrap(result);
}

ZigLLVMDILocation *ZigLLVMGetDebugLoc(unsigned line, unsigned col, ZigLLVMDIScope *scope) {
    DebugLoc debug_loc = DebugLoc::get(line, col, reinterpret_cast<DIScope*>(scope), nullptr);
    return reinterpret_cast<ZigLLVMDILocation*>(debug_loc.get());
}

void ZigLLVMSetFastMath(LLVMBuilderRef builder_wrapped, bool on_state) {
    if (on_state) {
        FastMathFlags fmf;
        fmf.setFast();
        unwrap(builder_wrapped)->setFastMathFlags(fmf);
    } else {
        unwrap(builder_wrapped)->clearFastMathFlags();
    }
}

void ZigLLVMAddByValAttr(LLVMValueRef fn_ref, unsigned ArgNo, LLVMTypeRef type_val) {
    Function *func = unwrap<Function>(fn_ref);
    const AttributeList attr_set = func->getAttributes();
    AttrBuilder attr_builder;
    Type *llvm_type = unwrap<Type>(type_val);
    attr_builder.addByValAttr(llvm_type);
    const AttributeList new_attr_set = attr_set.addAttributes(func->getContext(), ArgNo, attr_builder);
    func->setAttributes(new_attr_set);
}

void ZigLLVMAddFunctionAttr(LLVMValueRef fn_ref, const char *attr_name, const char *attr_value) {
    Function *func = unwrap<Function>(fn_ref);
    const AttributeList attr_set = func->getAttributes();
    AttrBuilder attr_builder;
    if (attr_value) {
        attr_builder.addAttribute(attr_name, attr_value);
    } else {
        attr_builder.addAttribute(attr_name);
    }
    const AttributeList new_attr_set = attr_set.addAttributes(func->getContext(),
            AttributeList::FunctionIndex, attr_builder);
    func->setAttributes(new_attr_set);
}

void ZigLLVMAddFunctionAttrCold(LLVMValueRef fn_ref) {
    Function *func = unwrap<Function>(fn_ref);
    const AttributeList attr_set = func->getAttributes();
    const AttributeList new_attr_set = attr_set.addAttribute(func->getContext(), AttributeList::FunctionIndex,
            Attribute::Cold);
    func->setAttributes(new_attr_set);
}

void ZigLLVMParseCommandLineOptions(size_t argc, const char *const *argv) {
    llvm::cl::ParseCommandLineOptions(argc, argv);
}

const char *ZigLLVMGetArchTypeName(ZigLLVM_ArchType arch) {
    return (const char*)Triple::getArchTypeName((Triple::ArchType)arch).bytes_begin();
}

const char *ZigLLVMGetVendorTypeName(ZigLLVM_VendorType vendor) {
    return (const char*)Triple::getVendorTypeName((Triple::VendorType)vendor).bytes_begin();
}

const char *ZigLLVMGetOSTypeName(ZigLLVM_OSType os) {
    return (const char*)Triple::getOSTypeName((Triple::OSType)os).bytes_begin();
}

const char *ZigLLVMGetEnvironmentTypeName(ZigLLVM_EnvironmentType env_type) {
    return (const char*)Triple::getEnvironmentTypeName((Triple::EnvironmentType)env_type).bytes_begin();
}

void ZigLLVMGetNativeTarget(ZigLLVM_ArchType *arch_type, ZigLLVM_SubArchType *sub_arch_type,
        ZigLLVM_VendorType *vendor_type, ZigLLVM_OSType *os_type, ZigLLVM_EnvironmentType *environ_type,
        ZigLLVM_ObjectFormatType *oformat)
{
    char *native_triple = LLVMGetDefaultTargetTriple();
    Triple triple(Triple::normalize(native_triple));

    *arch_type = (ZigLLVM_ArchType)triple.getArch();
    *sub_arch_type = (ZigLLVM_SubArchType)triple.getSubArch();
    *vendor_type = (ZigLLVM_VendorType)triple.getVendor();
    *os_type = (ZigLLVM_OSType)triple.getOS();
    *environ_type = (ZigLLVM_EnvironmentType)triple.getEnvironment();
    *oformat = (ZigLLVM_ObjectFormatType)triple.getObjectFormat();

    free(native_triple);
}

const char *ZigLLVMGetSubArchTypeName(ZigLLVM_SubArchType sub_arch) {
    switch (sub_arch) {
        case ZigLLVM_NoSubArch:
            return "";
        case ZigLLVM_ARMSubArch_v8_5a:
            return "v8.5a";
        case ZigLLVM_ARMSubArch_v8_4a:
            return "v8.4a";
        case ZigLLVM_ARMSubArch_v8_3a:
            return "v8.3a";
        case ZigLLVM_ARMSubArch_v8_2a:
            return "v8.2a";
        case ZigLLVM_ARMSubArch_v8_1a:
            return "v8.1a";
        case ZigLLVM_ARMSubArch_v8:
            return "v8";
        case ZigLLVM_ARMSubArch_v8r:
            return "v8r";
        case ZigLLVM_ARMSubArch_v8m_baseline:
            return "v8m.base";
        case ZigLLVM_ARMSubArch_v8m_mainline:
            return "v8m.main";
        case ZigLLVM_ARMSubArch_v8_1m_mainline:
            return "v8.1m.main";
        case ZigLLVM_ARMSubArch_v7:
            return "v7";
        case ZigLLVM_ARMSubArch_v7em:
            return "v7em";
        case ZigLLVM_ARMSubArch_v7m:
            return "v7m";
        case ZigLLVM_ARMSubArch_v7s:
            return "v7s";
        case ZigLLVM_ARMSubArch_v7k:
            return "v7k";
        case ZigLLVM_ARMSubArch_v7ve:
            return "v7ve";
        case ZigLLVM_ARMSubArch_v6:
            return "v6";
        case ZigLLVM_ARMSubArch_v6m:
            return "v6m";
        case ZigLLVM_ARMSubArch_v6k:
            return "v6k";
        case ZigLLVM_ARMSubArch_v6t2:
            return "v6t2";
        case ZigLLVM_ARMSubArch_v5:
            return "v5";
        case ZigLLVM_ARMSubArch_v5te:
            return "v5te";
        case ZigLLVM_ARMSubArch_v4t:
            return "v4t";
        case ZigLLVM_KalimbaSubArch_v3:
            return "v3";
        case ZigLLVM_KalimbaSubArch_v4:
            return "v4";
        case ZigLLVM_KalimbaSubArch_v5:
            return "v5";
        case ZigLLVM_MipsSubArch_r6:
            return "r6";
    }
    abort();
}

void ZigLLVMAddModuleDebugInfoFlag(LLVMModuleRef module) {
    unwrap(module)->addModuleFlag(Module::Warning, "Debug Info Version", DEBUG_METADATA_VERSION);
    unwrap(module)->addModuleFlag(Module::Warning, "Dwarf Version", 4);
}

void ZigLLVMAddModuleCodeViewFlag(LLVMModuleRef module) {
    unwrap(module)->addModuleFlag(Module::Warning, "CodeView", 1);
}

static AtomicOrdering mapFromLLVMOrdering(LLVMAtomicOrdering Ordering) {
    switch (Ordering) {
        case LLVMAtomicOrderingNotAtomic: return AtomicOrdering::NotAtomic;
        case LLVMAtomicOrderingUnordered: return AtomicOrdering::Unordered;
        case LLVMAtomicOrderingMonotonic: return AtomicOrdering::Monotonic;
        case LLVMAtomicOrderingAcquire: return AtomicOrdering::Acquire;
        case LLVMAtomicOrderingRelease: return AtomicOrdering::Release;
        case LLVMAtomicOrderingAcquireRelease: return AtomicOrdering::AcquireRelease;
        case LLVMAtomicOrderingSequentiallyConsistent: return AtomicOrdering::SequentiallyConsistent;
    }
    abort();
}

LLVMValueRef ZigLLVMBuildCmpXchg(LLVMBuilderRef builder, LLVMValueRef ptr, LLVMValueRef cmp,
        LLVMValueRef new_val, LLVMAtomicOrdering success_ordering,
        LLVMAtomicOrdering failure_ordering, bool is_weak)
{
    AtomicCmpXchgInst *inst = unwrap(builder)->CreateAtomicCmpXchg(unwrap(ptr), unwrap(cmp),
                unwrap(new_val), mapFromLLVMOrdering(success_ordering), mapFromLLVMOrdering(failure_ordering));
    inst->setWeak(is_weak);
    return wrap(inst);
}

LLVMValueRef ZigLLVMBuildNSWShl(LLVMBuilderRef builder, LLVMValueRef LHS, LLVMValueRef RHS,
        const char *name)
{
    return wrap(unwrap(builder)->CreateShl(unwrap(LHS), unwrap(RHS), name, false, true));
}

LLVMValueRef ZigLLVMBuildNUWShl(LLVMBuilderRef builder, LLVMValueRef LHS, LLVMValueRef RHS,
        const char *name)
{
    return wrap(unwrap(builder)->CreateShl(unwrap(LHS), unwrap(RHS), name, true, false));
}

LLVMValueRef ZigLLVMBuildLShrExact(LLVMBuilderRef builder, LLVMValueRef LHS, LLVMValueRef RHS,
        const char *name)
{
    return wrap(unwrap(builder)->CreateLShr(unwrap(LHS), unwrap(RHS), name, true));
}

LLVMValueRef ZigLLVMBuildAShrExact(LLVMBuilderRef builder, LLVMValueRef LHS, LLVMValueRef RHS,
        const char *name)
{
    return wrap(unwrap(builder)->CreateAShr(unwrap(LHS), unwrap(RHS), name, true));
}

void ZigLLVMSetTailCall(LLVMValueRef Call) {
    unwrap<CallInst>(Call)->setTailCallKind(CallInst::TCK_MustTail);
} 

void ZigLLVMFunctionSetPrefixData(LLVMValueRef function, LLVMValueRef data) {
    unwrap<Function>(function)->setPrefixData(unwrap<Constant>(data));
}


class MyOStream: public raw_ostream {
    public:
        MyOStream(void (*_append_diagnostic)(void *, const char *, size_t), void *_context) :
            raw_ostream(true), append_diagnostic(_append_diagnostic), context(_context), pos(0) {

        }
        void write_impl(const char *ptr, size_t len) override {
            append_diagnostic(context, ptr, len);
            pos += len;
        }
        uint64_t current_pos() const override {
            return pos;
        }
        void (*append_diagnostic)(void *, const char *, size_t);
        void *context;
        size_t pos;
};

bool ZigLLVMWriteImportLibrary(const char *def_path, const ZigLLVM_ArchType arch,
                               const char *output_lib_path, const bool kill_at)
{
    COFF::MachineTypes machine = COFF::IMAGE_FILE_MACHINE_UNKNOWN;

    switch (arch) {
        case ZigLLVM_x86:
            machine = COFF::IMAGE_FILE_MACHINE_I386;
            break;
        case ZigLLVM_x86_64:
            machine = COFF::IMAGE_FILE_MACHINE_AMD64;
            break;
        case ZigLLVM_arm:
        case ZigLLVM_armeb:
        case ZigLLVM_thumb:
        case ZigLLVM_thumbeb:
            machine = COFF::IMAGE_FILE_MACHINE_ARMNT;
            break;
        case ZigLLVM_aarch64:
        case ZigLLVM_aarch64_be:
            machine = COFF::IMAGE_FILE_MACHINE_ARM64;
            break;
        default:
            break;
    }

    if (machine == COFF::IMAGE_FILE_MACHINE_UNKNOWN) {
        return true;
    }

    auto bufOrErr = MemoryBuffer::getFile(def_path);
    if (!bufOrErr) {
        return false;
    }

    MemoryBuffer& buf = *bufOrErr.get();
    Expected<object::COFFModuleDefinition> def =
        object::parseCOFFModuleDefinition(buf, machine, /* MingwDef */ true);

    if (!def) {
        return true;
    }

    // The exports-juggling code below is ripped from LLVM's DllToolDriver.cpp

    // If ExtName is set (if the "ExtName = Name" syntax was used), overwrite
    // Name with ExtName and clear ExtName. When only creating an import
    // library and not linking, the internal name is irrelevant. This avoids
    // cases where writeImportLibrary tries to transplant decoration from
    // symbol decoration onto ExtName.
    for (object::COFFShortExport& E : def->Exports) {
        if (!E.ExtName.empty()) {
            E.Name = E.ExtName;
            E.ExtName.clear();
        }
    }

    if (machine == COFF::IMAGE_FILE_MACHINE_I386 && kill_at) {
        for (object::COFFShortExport& E : def->Exports) {
            if (!E.AliasTarget.empty() || (!E.Name.empty() && E.Name[0] == '?'))
                continue;
            E.SymbolName = E.Name;
            // Trim off the trailing decoration. Symbols will always have a
            // starting prefix here (either _ for cdecl/stdcall, @ for fastcall
            // or ? for C++ functions). Vectorcall functions won't have any
            // fixed prefix, but the function base name will still be at least
            // one char.
            E.Name = E.Name.substr(0, E.Name.find('@', 1));
            // By making sure E.SymbolName != E.Name for decorated symbols,
            // writeImportLibrary writes these symbols with the type
            // IMPORT_NAME_UNDECORATE.
        }
    }

    return static_cast<bool>(
        object::writeImportLibrary(def->OutputFile, output_lib_path,
                                   def->Exports, machine, /* MinGW */ true));
}

bool ZigLLVMWriteArchive(const char *archive_name, const char **file_names, size_t file_name_count,
        ZigLLVM_OSType os_type)
{
    object::Archive::Kind kind;
    switch (os_type) {
        case ZigLLVM_Win32:
            // For some reason llvm-lib passes K_GNU on windows.
            // See lib/ToolDrivers/llvm-lib/LibDriver.cpp:168 in libDriverMain
            kind = object::Archive::K_GNU;
            break;
        case ZigLLVM_Linux:
            kind = object::Archive::K_GNU;
            break;
        case ZigLLVM_MacOSX:
        case ZigLLVM_Darwin:
        case ZigLLVM_IOS:
            kind = object::Archive::K_DARWIN;
            break;
        case ZigLLVM_OpenBSD:
        case ZigLLVM_FreeBSD:
            kind = object::Archive::K_BSD;
            break;
        default:
            kind = object::Archive::K_GNU;
    }
    SmallVector<NewArchiveMember, 4> new_members;
    for (size_t i = 0; i < file_name_count; i += 1) {
        Expected<NewArchiveMember> new_member = NewArchiveMember::getFile(file_names[i], true);
        Error err = new_member.takeError();
        if (err) return true;
        new_members.push_back(std::move(*new_member));
    }
    Error err = writeArchive(archive_name, new_members, true, kind, true, false, nullptr);
    if (err) return true;
    return false;
}


bool ZigLLDLink(ZigLLVM_ObjectFormatType oformat, const char **args, size_t arg_count,
        void (*append_diagnostic)(void *, const char *, size_t), void *context)
{
    ArrayRef<const char *> array_ref_args(args, arg_count);

    MyOStream diag(append_diagnostic, context);

    switch (oformat) {
        case ZigLLVM_UnknownObjectFormat:
        case ZigLLVM_XCOFF:
            assert(false); // unreachable

        case ZigLLVM_COFF:
            return lld::coff::link(array_ref_args, false, diag);

        case ZigLLVM_ELF:
            return lld::elf::link(array_ref_args, false, diag);

        case ZigLLVM_MachO:
            return lld::mach_o::link(array_ref_args, false, diag);

        case ZigLLVM_Wasm:
            return lld::wasm::link(array_ref_args, false, diag);
    }
    assert(false); // unreachable
    abort();
}

static AtomicRMWInst::BinOp toLLVMRMWBinOp(enum ZigLLVM_AtomicRMWBinOp BinOp) {
    switch (BinOp) {
        default:
        case ZigLLVMAtomicRMWBinOpXchg: return AtomicRMWInst::Xchg;
        case ZigLLVMAtomicRMWBinOpAdd: return AtomicRMWInst::Add;
        case ZigLLVMAtomicRMWBinOpSub: return AtomicRMWInst::Sub;
        case ZigLLVMAtomicRMWBinOpAnd: return AtomicRMWInst::And;
        case ZigLLVMAtomicRMWBinOpNand: return AtomicRMWInst::Nand;
        case ZigLLVMAtomicRMWBinOpOr: return AtomicRMWInst::Or;
        case ZigLLVMAtomicRMWBinOpXor: return AtomicRMWInst::Xor;
        case ZigLLVMAtomicRMWBinOpMax: return AtomicRMWInst::Max;
        case ZigLLVMAtomicRMWBinOpMin: return AtomicRMWInst::Min;
        case ZigLLVMAtomicRMWBinOpUMax: return AtomicRMWInst::UMax;
        case ZigLLVMAtomicRMWBinOpUMin: return AtomicRMWInst::UMin;
        case ZigLLVMAtomicRMWBinOpFAdd: return AtomicRMWInst::FAdd;
        case ZigLLVMAtomicRMWBinOpFSub: return AtomicRMWInst::FSub;
    }
}

static AtomicOrdering toLLVMOrdering(LLVMAtomicOrdering Ordering) {
    switch (Ordering) {
        default:
        case LLVMAtomicOrderingNotAtomic: return AtomicOrdering::NotAtomic;
        case LLVMAtomicOrderingUnordered: return AtomicOrdering::Unordered;
        case LLVMAtomicOrderingMonotonic: return AtomicOrdering::Monotonic;
        case LLVMAtomicOrderingAcquire: return AtomicOrdering::Acquire;
        case LLVMAtomicOrderingRelease: return AtomicOrdering::Release;
        case LLVMAtomicOrderingAcquireRelease: return AtomicOrdering::AcquireRelease;
        case LLVMAtomicOrderingSequentiallyConsistent: return AtomicOrdering::SequentiallyConsistent;
    }
}

inline LLVMAttributeRef wrap(Attribute Attr) {
    return reinterpret_cast<LLVMAttributeRef>(Attr.getRawPointer());
}

inline Attribute unwrap(LLVMAttributeRef Attr) {
    return Attribute::fromRawPointer(Attr);
}

LLVMValueRef ZigLLVMBuildAtomicRMW(LLVMBuilderRef B, enum ZigLLVM_AtomicRMWBinOp op,
    LLVMValueRef PTR, LLVMValueRef Val,
    LLVMAtomicOrdering ordering, LLVMBool singleThread) 
{
    AtomicRMWInst::BinOp intop = toLLVMRMWBinOp(op);
    return wrap(unwrap(B)->CreateAtomicRMW(intop, unwrap(PTR),
        unwrap(Val), toLLVMOrdering(ordering), 
        singleThread ? SyncScope::SingleThread : SyncScope::System));
}

static_assert((Triple::ArchType)ZigLLVM_UnknownArch == Triple::UnknownArch, "");
static_assert((Triple::ArchType)ZigLLVM_arm == Triple::arm, "");
static_assert((Triple::ArchType)ZigLLVM_armeb == Triple::armeb, "");
static_assert((Triple::ArchType)ZigLLVM_aarch64 == Triple::aarch64, "");
static_assert((Triple::ArchType)ZigLLVM_aarch64_be == Triple::aarch64_be, "");
static_assert((Triple::ArchType)ZigLLVM_arc == Triple::arc, "");
static_assert((Triple::ArchType)ZigLLVM_avr == Triple::avr, "");
static_assert((Triple::ArchType)ZigLLVM_bpfel == Triple::bpfel, "");
static_assert((Triple::ArchType)ZigLLVM_bpfeb == Triple::bpfeb, "");
static_assert((Triple::ArchType)ZigLLVM_hexagon == Triple::hexagon, "");
static_assert((Triple::ArchType)ZigLLVM_mips == Triple::mips, "");
static_assert((Triple::ArchType)ZigLLVM_mipsel == Triple::mipsel, "");
static_assert((Triple::ArchType)ZigLLVM_mips64 == Triple::mips64, "");
static_assert((Triple::ArchType)ZigLLVM_mips64el == Triple::mips64el, "");
static_assert((Triple::ArchType)ZigLLVM_msp430 == Triple::msp430, "");
static_assert((Triple::ArchType)ZigLLVM_ppc == Triple::ppc, "");
static_assert((Triple::ArchType)ZigLLVM_ppc64 == Triple::ppc64, "");
static_assert((Triple::ArchType)ZigLLVM_ppc64le == Triple::ppc64le, "");
static_assert((Triple::ArchType)ZigLLVM_r600 == Triple::r600, "");
static_assert((Triple::ArchType)ZigLLVM_amdgcn == Triple::amdgcn, "");
static_assert((Triple::ArchType)ZigLLVM_riscv32 == Triple::riscv32, "");
static_assert((Triple::ArchType)ZigLLVM_riscv64 == Triple::riscv64, "");
static_assert((Triple::ArchType)ZigLLVM_sparc == Triple::sparc, "");
static_assert((Triple::ArchType)ZigLLVM_sparcv9 == Triple::sparcv9, "");
static_assert((Triple::ArchType)ZigLLVM_sparcel == Triple::sparcel, "");
static_assert((Triple::ArchType)ZigLLVM_systemz == Triple::systemz, "");
static_assert((Triple::ArchType)ZigLLVM_tce == Triple::tce, "");
static_assert((Triple::ArchType)ZigLLVM_tcele == Triple::tcele, "");
static_assert((Triple::ArchType)ZigLLVM_thumb == Triple::thumb, "");
static_assert((Triple::ArchType)ZigLLVM_thumbeb == Triple::thumbeb, "");
static_assert((Triple::ArchType)ZigLLVM_x86 == Triple::x86, "");
static_assert((Triple::ArchType)ZigLLVM_x86_64 == Triple::x86_64, "");
static_assert((Triple::ArchType)ZigLLVM_xcore == Triple::xcore, "");
static_assert((Triple::ArchType)ZigLLVM_nvptx == Triple::nvptx, "");
static_assert((Triple::ArchType)ZigLLVM_nvptx64 == Triple::nvptx64, "");
static_assert((Triple::ArchType)ZigLLVM_le32 == Triple::le32, "");
static_assert((Triple::ArchType)ZigLLVM_le64 == Triple::le64, "");
static_assert((Triple::ArchType)ZigLLVM_amdil == Triple::amdil, "");
static_assert((Triple::ArchType)ZigLLVM_amdil64 == Triple::amdil64, "");
static_assert((Triple::ArchType)ZigLLVM_hsail == Triple::hsail, "");
static_assert((Triple::ArchType)ZigLLVM_hsail64 == Triple::hsail64, "");
static_assert((Triple::ArchType)ZigLLVM_spir == Triple::spir, "");
static_assert((Triple::ArchType)ZigLLVM_spir64 == Triple::spir64, "");
static_assert((Triple::ArchType)ZigLLVM_kalimba == Triple::kalimba, "");
static_assert((Triple::ArchType)ZigLLVM_shave == Triple::shave, "");
static_assert((Triple::ArchType)ZigLLVM_lanai == Triple::lanai, "");
static_assert((Triple::ArchType)ZigLLVM_wasm32 == Triple::wasm32, "");
static_assert((Triple::ArchType)ZigLLVM_wasm64 == Triple::wasm64, "");
static_assert((Triple::ArchType)ZigLLVM_renderscript32 == Triple::renderscript32, "");
static_assert((Triple::ArchType)ZigLLVM_renderscript64 == Triple::renderscript64, "");
static_assert((Triple::ArchType)ZigLLVM_LastArchType == Triple::LastArchType, "");

static_assert((Triple::SubArchType)ZigLLVM_NoSubArch == Triple::NoSubArch, "");
static_assert((Triple::SubArchType)ZigLLVM_ARMSubArch_v8_4a == Triple::ARMSubArch_v8_4a, "");
static_assert((Triple::SubArchType)ZigLLVM_ARMSubArch_v8_3a == Triple::ARMSubArch_v8_3a, "");
static_assert((Triple::SubArchType)ZigLLVM_ARMSubArch_v8_2a == Triple::ARMSubArch_v8_2a, "");
static_assert((Triple::SubArchType)ZigLLVM_ARMSubArch_v8_1a == Triple::ARMSubArch_v8_1a, "");
static_assert((Triple::SubArchType)ZigLLVM_ARMSubArch_v8 == Triple::ARMSubArch_v8, "");
static_assert((Triple::SubArchType)ZigLLVM_ARMSubArch_v8r == Triple::ARMSubArch_v8r, "");
static_assert((Triple::SubArchType)ZigLLVM_ARMSubArch_v8m_baseline == Triple::ARMSubArch_v8m_baseline, "");
static_assert((Triple::SubArchType)ZigLLVM_ARMSubArch_v8m_mainline == Triple::ARMSubArch_v8m_mainline, "");
static_assert((Triple::SubArchType)ZigLLVM_ARMSubArch_v8_1m_mainline == Triple::ARMSubArch_v8_1m_mainline, "");
static_assert((Triple::SubArchType)ZigLLVM_ARMSubArch_v7 == Triple::ARMSubArch_v7, "");
static_assert((Triple::SubArchType)ZigLLVM_ARMSubArch_v7em == Triple::ARMSubArch_v7em, "");
static_assert((Triple::SubArchType)ZigLLVM_ARMSubArch_v7m == Triple::ARMSubArch_v7m, "");
static_assert((Triple::SubArchType)ZigLLVM_ARMSubArch_v7s == Triple::ARMSubArch_v7s, "");
static_assert((Triple::SubArchType)ZigLLVM_ARMSubArch_v7k == Triple::ARMSubArch_v7k, "");
static_assert((Triple::SubArchType)ZigLLVM_ARMSubArch_v7ve == Triple::ARMSubArch_v7ve, "");
static_assert((Triple::SubArchType)ZigLLVM_ARMSubArch_v6 == Triple::ARMSubArch_v6, "");
static_assert((Triple::SubArchType)ZigLLVM_ARMSubArch_v6m == Triple::ARMSubArch_v6m, "");
static_assert((Triple::SubArchType)ZigLLVM_ARMSubArch_v6k == Triple::ARMSubArch_v6k, "");
static_assert((Triple::SubArchType)ZigLLVM_ARMSubArch_v6t2 == Triple::ARMSubArch_v6t2, "");
static_assert((Triple::SubArchType)ZigLLVM_ARMSubArch_v5 == Triple::ARMSubArch_v5, "");
static_assert((Triple::SubArchType)ZigLLVM_ARMSubArch_v5te == Triple::ARMSubArch_v5te, "");
static_assert((Triple::SubArchType)ZigLLVM_ARMSubArch_v4t == Triple::ARMSubArch_v4t, "");
static_assert((Triple::SubArchType)ZigLLVM_KalimbaSubArch_v3 == Triple::KalimbaSubArch_v3, "");
static_assert((Triple::SubArchType)ZigLLVM_KalimbaSubArch_v4 == Triple::KalimbaSubArch_v4, "");
static_assert((Triple::SubArchType)ZigLLVM_KalimbaSubArch_v5 == Triple::KalimbaSubArch_v5, "");
static_assert((Triple::SubArchType)ZigLLVM_KalimbaSubArch_v5 == Triple::KalimbaSubArch_v5, "");
static_assert((Triple::SubArchType)ZigLLVM_MipsSubArch_r6 == Triple::MipsSubArch_r6, "");

static_assert((Triple::VendorType)ZigLLVM_UnknownVendor == Triple::UnknownVendor, "");
static_assert((Triple::VendorType)ZigLLVM_Apple == Triple::Apple, "");
static_assert((Triple::VendorType)ZigLLVM_PC == Triple::PC, "");
static_assert((Triple::VendorType)ZigLLVM_SCEI == Triple::SCEI, "");
static_assert((Triple::VendorType)ZigLLVM_BGP == Triple::BGP, "");
static_assert((Triple::VendorType)ZigLLVM_BGQ == Triple::BGQ, "");
static_assert((Triple::VendorType)ZigLLVM_Freescale == Triple::Freescale, "");
static_assert((Triple::VendorType)ZigLLVM_IBM == Triple::IBM, "");
static_assert((Triple::VendorType)ZigLLVM_ImaginationTechnologies == Triple::ImaginationTechnologies, "");
static_assert((Triple::VendorType)ZigLLVM_MipsTechnologies == Triple::MipsTechnologies, "");
static_assert((Triple::VendorType)ZigLLVM_NVIDIA == Triple::NVIDIA, "");
static_assert((Triple::VendorType)ZigLLVM_CSR == Triple::CSR, "");
static_assert((Triple::VendorType)ZigLLVM_Myriad == Triple::Myriad, "");
static_assert((Triple::VendorType)ZigLLVM_AMD == Triple::AMD, "");
static_assert((Triple::VendorType)ZigLLVM_Mesa == Triple::Mesa, "");
static_assert((Triple::VendorType)ZigLLVM_SUSE == Triple::SUSE, "");
static_assert((Triple::VendorType)ZigLLVM_OpenEmbedded == Triple::OpenEmbedded, "");
static_assert((Triple::VendorType)ZigLLVM_LastVendorType == Triple::LastVendorType, "");

static_assert((Triple::OSType)ZigLLVM_UnknownOS == Triple::UnknownOS, "");
static_assert((Triple::OSType)ZigLLVM_Ananas == Triple::Ananas, "");
static_assert((Triple::OSType)ZigLLVM_CloudABI == Triple::CloudABI, "");
static_assert((Triple::OSType)ZigLLVM_Darwin == Triple::Darwin, "");
static_assert((Triple::OSType)ZigLLVM_DragonFly == Triple::DragonFly, "");
static_assert((Triple::OSType)ZigLLVM_FreeBSD == Triple::FreeBSD, "");
static_assert((Triple::OSType)ZigLLVM_Fuchsia == Triple::Fuchsia, "");
static_assert((Triple::OSType)ZigLLVM_IOS == Triple::IOS, "");
// Commented out to work around a Debian/Ubuntu bug.
// See https://github.com/ziglang/zig/issues/2076
//static_assert((Triple::OSType)ZigLLVM_KFreeBSD == Triple::KFreeBSD, "");
static_assert((Triple::OSType)ZigLLVM_Linux == Triple::Linux, "");
static_assert((Triple::OSType)ZigLLVM_Lv2 == Triple::Lv2, "");
static_assert((Triple::OSType)ZigLLVM_MacOSX == Triple::MacOSX, "");
static_assert((Triple::OSType)ZigLLVM_NetBSD == Triple::NetBSD, "");
static_assert((Triple::OSType)ZigLLVM_OpenBSD == Triple::OpenBSD, "");
static_assert((Triple::OSType)ZigLLVM_Solaris == Triple::Solaris, "");
static_assert((Triple::OSType)ZigLLVM_Win32 == Triple::Win32, "");
static_assert((Triple::OSType)ZigLLVM_Haiku == Triple::Haiku, "");
static_assert((Triple::OSType)ZigLLVM_Minix == Triple::Minix, "");
static_assert((Triple::OSType)ZigLLVM_RTEMS == Triple::RTEMS, "");
static_assert((Triple::OSType)ZigLLVM_NaCl == Triple::NaCl, "");
static_assert((Triple::OSType)ZigLLVM_CNK == Triple::CNK, "");
static_assert((Triple::OSType)ZigLLVM_AIX == Triple::AIX, "");
static_assert((Triple::OSType)ZigLLVM_CUDA == Triple::CUDA, "");
static_assert((Triple::OSType)ZigLLVM_NVCL == Triple::NVCL, "");
static_assert((Triple::OSType)ZigLLVM_AMDHSA == Triple::AMDHSA, "");
static_assert((Triple::OSType)ZigLLVM_PS4 == Triple::PS4, "");
static_assert((Triple::OSType)ZigLLVM_ELFIAMCU == Triple::ELFIAMCU, "");
static_assert((Triple::OSType)ZigLLVM_TvOS == Triple::TvOS, "");
static_assert((Triple::OSType)ZigLLVM_WatchOS == Triple::WatchOS, "");
static_assert((Triple::OSType)ZigLLVM_Mesa3D == Triple::Mesa3D, "");
static_assert((Triple::OSType)ZigLLVM_Contiki == Triple::Contiki, "");
static_assert((Triple::OSType)ZigLLVM_AMDPAL == Triple::AMDPAL, "");
static_assert((Triple::OSType)ZigLLVM_HermitCore == Triple::HermitCore, "");
static_assert((Triple::OSType)ZigLLVM_Hurd == Triple::Hurd, "");
static_assert((Triple::OSType)ZigLLVM_WASI == Triple::WASI, "");
static_assert((Triple::OSType)ZigLLVM_Emscripten == Triple::Emscripten, "");
static_assert((Triple::OSType)ZigLLVM_LastOSType == Triple::LastOSType, "");

static_assert((Triple::EnvironmentType)ZigLLVM_UnknownEnvironment == Triple::UnknownEnvironment, "");
static_assert((Triple::EnvironmentType)ZigLLVM_GNU == Triple::GNU, "");
static_assert((Triple::EnvironmentType)ZigLLVM_GNUABIN32 == Triple::GNUABIN32, "");
static_assert((Triple::EnvironmentType)ZigLLVM_GNUABI64 == Triple::GNUABI64, "");
static_assert((Triple::EnvironmentType)ZigLLVM_GNUEABI == Triple::GNUEABI, "");
static_assert((Triple::EnvironmentType)ZigLLVM_GNUEABIHF == Triple::GNUEABIHF, "");
static_assert((Triple::EnvironmentType)ZigLLVM_GNUX32 == Triple::GNUX32, "");
static_assert((Triple::EnvironmentType)ZigLLVM_CODE16 == Triple::CODE16, "");
static_assert((Triple::EnvironmentType)ZigLLVM_EABI == Triple::EABI, "");
static_assert((Triple::EnvironmentType)ZigLLVM_EABIHF == Triple::EABIHF, "");
static_assert((Triple::EnvironmentType)ZigLLVM_ELFv1 == Triple::ELFv1, "");
static_assert((Triple::EnvironmentType)ZigLLVM_ELFv2 == Triple::ELFv2, "");
static_assert((Triple::EnvironmentType)ZigLLVM_Android == Triple::Android, "");
static_assert((Triple::EnvironmentType)ZigLLVM_Musl == Triple::Musl, "");
static_assert((Triple::EnvironmentType)ZigLLVM_MuslEABI == Triple::MuslEABI, "");
static_assert((Triple::EnvironmentType)ZigLLVM_MuslEABIHF == Triple::MuslEABIHF, "");
static_assert((Triple::EnvironmentType)ZigLLVM_MSVC == Triple::MSVC, "");
static_assert((Triple::EnvironmentType)ZigLLVM_Itanium == Triple::Itanium, "");
static_assert((Triple::EnvironmentType)ZigLLVM_Cygnus == Triple::Cygnus, "");
static_assert((Triple::EnvironmentType)ZigLLVM_CoreCLR == Triple::CoreCLR, "");
static_assert((Triple::EnvironmentType)ZigLLVM_Simulator == Triple::Simulator, "");
static_assert((Triple::EnvironmentType)ZigLLVM_LastEnvironmentType == Triple::LastEnvironmentType, "");

static_assert((Triple::ObjectFormatType)ZigLLVM_UnknownObjectFormat == Triple::UnknownObjectFormat, "");
static_assert((Triple::ObjectFormatType)ZigLLVM_COFF == Triple::COFF, "");
static_assert((Triple::ObjectFormatType)ZigLLVM_ELF == Triple::ELF, "");
static_assert((Triple::ObjectFormatType)ZigLLVM_MachO == Triple::MachO, "");
static_assert((Triple::ObjectFormatType)ZigLLVM_Wasm == Triple::Wasm, "");
static_assert((Triple::ObjectFormatType)ZigLLVM_XCOFF == Triple::XCOFF, "");
