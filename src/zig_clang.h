/*
 * Copyright (c) 2019 Andrew Kelley
 *
 * This file is part of zig, which is MIT licensed.
 * See http://opensource.org/licenses/MIT
 */

#ifndef ZIG_ZIG_CLANG_H
#define ZIG_ZIG_CLANG_H

#include "userland.h"
#include <inttypes.h>
#include <stdbool.h>

// ATTENTION: If you modify this file, be sure to update the corresponding
// extern function declarations in the self-hosted compiler file
// src-self-hosted/clang.zig.

struct ZigClangSourceLocation {
    unsigned ID;
};

struct ZigClangQualType {
    void *ptr;
};

struct ZigClangAPValueLValueBase {
    void *Ptr;
    unsigned CallIndex;
    unsigned Version;
};

enum ZigClangAPValueKind {
    ZigClangAPValueNone,
    ZigClangAPValueIndeterminate,
    ZigClangAPValueInt,
    ZigClangAPValueFloat,
    ZigClangAPValueFixedPoint,
    ZigClangAPValueComplexInt,
    ZigClangAPValueComplexFloat,
    ZigClangAPValueLValue,
    ZigClangAPValueVector,
    ZigClangAPValueArray,
    ZigClangAPValueStruct,
    ZigClangAPValueUnion,
    ZigClangAPValueMemberPointer,
    ZigClangAPValueAddrLabelDiff,
};

struct ZigClangAPValue {
    enum ZigClangAPValueKind Kind;
    // experimentally-derived size of clang::APValue::DataType
#if defined(_WIN32) && defined(_MSC_VER)
    char Data[52];
#else
    char Data[68];
#endif
};

struct ZigClangExprEvalResult {
    bool HasSideEffects;
    bool HasUndefinedBehavior;
    void *SmallVectorImpl;
    ZigClangAPValue Val;
};

struct ZigClangAPFloat;
struct ZigClangAPInt;
struct ZigClangAPSInt;
struct ZigClangAPValue;
struct ZigClangASTContext;
struct ZigClangASTUnit;
struct ZigClangArraySubscriptExpr;
struct ZigClangArrayType;
struct ZigClangAttributedType;
struct ZigClangBinaryOperator;
struct ZigClangBreakStmt;
struct ZigClangBuiltinType;
struct ZigClangCStyleCastExpr;
struct ZigClangCallExpr;
struct ZigClangCaseStmt;
struct ZigClangCharacterLiteral;
struct ZigClangCompoundAssignOperator;
struct ZigClangCompoundStmt;
struct ZigClangConditionalOperator;
struct ZigClangConstantArrayType;
struct ZigClangConstantExpr;
struct ZigClangContinueStmt;
struct ZigClangDecayedType;
struct ZigClangDecl;
struct ZigClangDeclRefExpr;
struct ZigClangDeclStmt;
struct ZigClangDefaultStmt;
struct ZigClangDiagnosticOptions;
struct ZigClangDiagnosticsEngine;
struct ZigClangDoStmt;
struct ZigClangElaboratedType;
struct ZigClangEnumConstantDecl;
struct ZigClangEnumDecl;
struct ZigClangEnumType;
struct ZigClangExpr;
struct ZigClangFieldDecl;
struct ZigClangFileID;
struct ZigClangFloatingLiteral;
struct ZigClangForStmt;
struct ZigClangFullSourceLoc;
struct ZigClangFunctionDecl;
struct ZigClangFunctionProtoType;
struct ZigClangFunctionType;
struct ZigClangIfStmt;
struct ZigClangImplicitCastExpr;
struct ZigClangIncompleteArrayType;
struct ZigClangIntegerLiteral;
struct ZigClangMacroDefinitionRecord;
struct ZigClangMacroQualifiedType;
struct ZigClangMemberExpr;
struct ZigClangNamedDecl;
struct ZigClangNone;
struct ZigClangPCHContainerOperations;
struct ZigClangParenExpr;
struct ZigClangParenType;
struct ZigClangParmVarDecl;
struct ZigClangPointerType;
struct ZigClangPredefinedExpr;
struct ZigClangPreprocessedEntity;
struct ZigClangPreprocessingRecord;
struct ZigClangRecordDecl;
struct ZigClangRecordType;
struct ZigClangReturnStmt;
struct ZigClangSkipFunctionBodiesScope;
struct ZigClangSourceManager;
struct ZigClangSourceRange;
struct ZigClangStmt;
struct ZigClangStmtExpr;
struct ZigClangStringLiteral;
struct ZigClangStringRef;
struct ZigClangSwitchStmt;
struct ZigClangTagDecl;
struct ZigClangType;
struct ZigClangTypedefNameDecl;
struct ZigClangTypedefType;
struct ZigClangUnaryExprOrTypeTraitExpr;
struct ZigClangUnaryOperator;
struct ZigClangValueDecl;
struct ZigClangVarDecl;
struct ZigClangWhileStmt;
struct ZigClangInitListExpr;

typedef struct ZigClangStmt *const * ZigClangCompoundStmt_const_body_iterator;
typedef struct ZigClangDecl *const * ZigClangDeclStmt_const_decl_iterator;

struct ZigClangRecordDecl_field_iterator {
    void *opaque;
};

struct ZigClangEnumDecl_enumerator_iterator {
    void *opaque;
};

struct ZigClangPreprocessingRecord_iterator {
    int I;
    struct ZigClangPreprocessingRecord *Self;
};

enum ZigClangBO {
    ZigClangBO_PtrMemD,
    ZigClangBO_PtrMemI,
    ZigClangBO_Mul,
    ZigClangBO_Div,
    ZigClangBO_Rem,
    ZigClangBO_Add,
    ZigClangBO_Sub,
    ZigClangBO_Shl,
    ZigClangBO_Shr,
    ZigClangBO_Cmp,
    ZigClangBO_LT,
    ZigClangBO_GT,
    ZigClangBO_LE,
    ZigClangBO_GE,
    ZigClangBO_EQ,
    ZigClangBO_NE,
    ZigClangBO_And,
    ZigClangBO_Xor,
    ZigClangBO_Or,
    ZigClangBO_LAnd,
    ZigClangBO_LOr,
    ZigClangBO_Assign,
    ZigClangBO_MulAssign,
    ZigClangBO_DivAssign,
    ZigClangBO_RemAssign,
    ZigClangBO_AddAssign,
    ZigClangBO_SubAssign,
    ZigClangBO_ShlAssign,
    ZigClangBO_ShrAssign,
    ZigClangBO_AndAssign,
    ZigClangBO_XorAssign,
    ZigClangBO_OrAssign,
    ZigClangBO_Comma,
};

enum ZigClangUO {
    ZigClangUO_PostInc,
    ZigClangUO_PostDec,
    ZigClangUO_PreInc,
    ZigClangUO_PreDec,
    ZigClangUO_AddrOf,
    ZigClangUO_Deref,
    ZigClangUO_Plus,
    ZigClangUO_Minus,
    ZigClangUO_Not,
    ZigClangUO_LNot,
    ZigClangUO_Real,
    ZigClangUO_Imag,
    ZigClangUO_Extension,
    ZigClangUO_Coawait,
};

enum ZigClangTypeClass {
    ZigClangType_Builtin,
    ZigClangType_Complex,
    ZigClangType_Pointer,
    ZigClangType_BlockPointer,
    ZigClangType_LValueReference,
    ZigClangType_RValueReference,
    ZigClangType_MemberPointer,
    ZigClangType_ConstantArray,
    ZigClangType_IncompleteArray,
    ZigClangType_VariableArray,
    ZigClangType_DependentSizedArray,
    ZigClangType_DependentSizedExtVector,
    ZigClangType_DependentAddressSpace,
    ZigClangType_Vector,
    ZigClangType_DependentVector,
    ZigClangType_ExtVector,
    ZigClangType_FunctionProto,
    ZigClangType_FunctionNoProto,
    ZigClangType_UnresolvedUsing,
    ZigClangType_Paren,
    ZigClangType_Typedef,
    ZigClangType_MacroQualified,
    ZigClangType_Adjusted,
    ZigClangType_Decayed,
    ZigClangType_TypeOfExpr,
    ZigClangType_TypeOf,
    ZigClangType_Decltype,
    ZigClangType_UnaryTransform,
    ZigClangType_Record,
    ZigClangType_Enum,
    ZigClangType_Elaborated,
    ZigClangType_Attributed,
    ZigClangType_TemplateTypeParm,
    ZigClangType_SubstTemplateTypeParm,
    ZigClangType_SubstTemplateTypeParmPack,
    ZigClangType_TemplateSpecialization,
    ZigClangType_Auto,
    ZigClangType_DeducedTemplateSpecialization,
    ZigClangType_InjectedClassName,
    ZigClangType_DependentName,
    ZigClangType_DependentTemplateSpecialization,
    ZigClangType_PackExpansion,
    ZigClangType_ObjCTypeParam,
    ZigClangType_ObjCObject,
    ZigClangType_ObjCInterface,
    ZigClangType_ObjCObjectPointer,
    ZigClangType_Pipe,
    ZigClangType_Atomic,
};

enum ZigClangStmtClass {
    ZigClangStmt_NoStmtClass,
    ZigClangStmt_GCCAsmStmtClass,
    ZigClangStmt_MSAsmStmtClass,
    ZigClangStmt_BreakStmtClass,
    ZigClangStmt_CXXCatchStmtClass,
    ZigClangStmt_CXXForRangeStmtClass,
    ZigClangStmt_CXXTryStmtClass,
    ZigClangStmt_CapturedStmtClass,
    ZigClangStmt_CompoundStmtClass,
    ZigClangStmt_ContinueStmtClass,
    ZigClangStmt_CoreturnStmtClass,
    ZigClangStmt_CoroutineBodyStmtClass,
    ZigClangStmt_DeclStmtClass,
    ZigClangStmt_DoStmtClass,
    ZigClangStmt_ForStmtClass,
    ZigClangStmt_GotoStmtClass,
    ZigClangStmt_IfStmtClass,
    ZigClangStmt_IndirectGotoStmtClass,
    ZigClangStmt_MSDependentExistsStmtClass,
    ZigClangStmt_NullStmtClass,
    ZigClangStmt_OMPAtomicDirectiveClass,
    ZigClangStmt_OMPBarrierDirectiveClass,
    ZigClangStmt_OMPCancelDirectiveClass,
    ZigClangStmt_OMPCancellationPointDirectiveClass,
    ZigClangStmt_OMPCriticalDirectiveClass,
    ZigClangStmt_OMPFlushDirectiveClass,
    ZigClangStmt_OMPDistributeDirectiveClass,
    ZigClangStmt_OMPDistributeParallelForDirectiveClass,
    ZigClangStmt_OMPDistributeParallelForSimdDirectiveClass,
    ZigClangStmt_OMPDistributeSimdDirectiveClass,
    ZigClangStmt_OMPForDirectiveClass,
    ZigClangStmt_OMPForSimdDirectiveClass,
    ZigClangStmt_OMPParallelForDirectiveClass,
    ZigClangStmt_OMPParallelForSimdDirectiveClass,
    ZigClangStmt_OMPSimdDirectiveClass,
    ZigClangStmt_OMPTargetParallelForSimdDirectiveClass,
    ZigClangStmt_OMPTargetSimdDirectiveClass,
    ZigClangStmt_OMPTargetTeamsDistributeDirectiveClass,
    ZigClangStmt_OMPTargetTeamsDistributeParallelForDirectiveClass,
    ZigClangStmt_OMPTargetTeamsDistributeParallelForSimdDirectiveClass,
    ZigClangStmt_OMPTargetTeamsDistributeSimdDirectiveClass,
    ZigClangStmt_OMPTaskLoopDirectiveClass,
    ZigClangStmt_OMPTaskLoopSimdDirectiveClass,
    ZigClangStmt_OMPTeamsDistributeDirectiveClass,
    ZigClangStmt_OMPTeamsDistributeParallelForDirectiveClass,
    ZigClangStmt_OMPTeamsDistributeParallelForSimdDirectiveClass,
    ZigClangStmt_OMPTeamsDistributeSimdDirectiveClass,
    ZigClangStmt_OMPMasterDirectiveClass,
    ZigClangStmt_OMPOrderedDirectiveClass,
    ZigClangStmt_OMPParallelDirectiveClass,
    ZigClangStmt_OMPParallelSectionsDirectiveClass,
    ZigClangStmt_OMPSectionDirectiveClass,
    ZigClangStmt_OMPSectionsDirectiveClass,
    ZigClangStmt_OMPSingleDirectiveClass,
    ZigClangStmt_OMPTargetDataDirectiveClass,
    ZigClangStmt_OMPTargetDirectiveClass,
    ZigClangStmt_OMPTargetEnterDataDirectiveClass,
    ZigClangStmt_OMPTargetExitDataDirectiveClass,
    ZigClangStmt_OMPTargetParallelDirectiveClass,
    ZigClangStmt_OMPTargetParallelForDirectiveClass,
    ZigClangStmt_OMPTargetTeamsDirectiveClass,
    ZigClangStmt_OMPTargetUpdateDirectiveClass,
    ZigClangStmt_OMPTaskDirectiveClass,
    ZigClangStmt_OMPTaskgroupDirectiveClass,
    ZigClangStmt_OMPTaskwaitDirectiveClass,
    ZigClangStmt_OMPTaskyieldDirectiveClass,
    ZigClangStmt_OMPTeamsDirectiveClass,
    ZigClangStmt_ObjCAtCatchStmtClass,
    ZigClangStmt_ObjCAtFinallyStmtClass,
    ZigClangStmt_ObjCAtSynchronizedStmtClass,
    ZigClangStmt_ObjCAtThrowStmtClass,
    ZigClangStmt_ObjCAtTryStmtClass,
    ZigClangStmt_ObjCAutoreleasePoolStmtClass,
    ZigClangStmt_ObjCForCollectionStmtClass,
    ZigClangStmt_ReturnStmtClass,
    ZigClangStmt_SEHExceptStmtClass,
    ZigClangStmt_SEHFinallyStmtClass,
    ZigClangStmt_SEHLeaveStmtClass,
    ZigClangStmt_SEHTryStmtClass,
    ZigClangStmt_CaseStmtClass,
    ZigClangStmt_DefaultStmtClass,
    ZigClangStmt_SwitchStmtClass,
    ZigClangStmt_AttributedStmtClass,
    ZigClangStmt_BinaryConditionalOperatorClass,
    ZigClangStmt_ConditionalOperatorClass,
    ZigClangStmt_AddrLabelExprClass,
    ZigClangStmt_ArrayInitIndexExprClass,
    ZigClangStmt_ArrayInitLoopExprClass,
    ZigClangStmt_ArraySubscriptExprClass,
    ZigClangStmt_ArrayTypeTraitExprClass,
    ZigClangStmt_AsTypeExprClass,
    ZigClangStmt_AtomicExprClass,
    ZigClangStmt_BinaryOperatorClass,
    ZigClangStmt_CompoundAssignOperatorClass,
    ZigClangStmt_BlockExprClass,
    ZigClangStmt_CXXBindTemporaryExprClass,
    ZigClangStmt_CXXBoolLiteralExprClass,
    ZigClangStmt_CXXConstructExprClass,
    ZigClangStmt_CXXTemporaryObjectExprClass,
    ZigClangStmt_CXXDefaultArgExprClass,
    ZigClangStmt_CXXDefaultInitExprClass,
    ZigClangStmt_CXXDeleteExprClass,
    ZigClangStmt_CXXDependentScopeMemberExprClass,
    ZigClangStmt_CXXFoldExprClass,
    ZigClangStmt_CXXInheritedCtorInitExprClass,
    ZigClangStmt_CXXNewExprClass,
    ZigClangStmt_CXXNoexceptExprClass,
    ZigClangStmt_CXXNullPtrLiteralExprClass,
    ZigClangStmt_CXXPseudoDestructorExprClass,
    ZigClangStmt_CXXScalarValueInitExprClass,
    ZigClangStmt_CXXStdInitializerListExprClass,
    ZigClangStmt_CXXThisExprClass,
    ZigClangStmt_CXXThrowExprClass,
    ZigClangStmt_CXXTypeidExprClass,
    ZigClangStmt_CXXUnresolvedConstructExprClass,
    ZigClangStmt_CXXUuidofExprClass,
    ZigClangStmt_CallExprClass,
    ZigClangStmt_CUDAKernelCallExprClass,
    ZigClangStmt_CXXMemberCallExprClass,
    ZigClangStmt_CXXOperatorCallExprClass,
    ZigClangStmt_UserDefinedLiteralClass,
    ZigClangStmt_BuiltinBitCastExprClass,
    ZigClangStmt_CStyleCastExprClass,
    ZigClangStmt_CXXFunctionalCastExprClass,
    ZigClangStmt_CXXConstCastExprClass,
    ZigClangStmt_CXXDynamicCastExprClass,
    ZigClangStmt_CXXReinterpretCastExprClass,
    ZigClangStmt_CXXStaticCastExprClass,
    ZigClangStmt_ObjCBridgedCastExprClass,
    ZigClangStmt_ImplicitCastExprClass,
    ZigClangStmt_CharacterLiteralClass,
    ZigClangStmt_ChooseExprClass,
    ZigClangStmt_CompoundLiteralExprClass,
    ZigClangStmt_ConvertVectorExprClass,
    ZigClangStmt_CoawaitExprClass,
    ZigClangStmt_CoyieldExprClass,
    ZigClangStmt_DeclRefExprClass,
    ZigClangStmt_DependentCoawaitExprClass,
    ZigClangStmt_DependentScopeDeclRefExprClass,
    ZigClangStmt_DesignatedInitExprClass,
    ZigClangStmt_DesignatedInitUpdateExprClass,
    ZigClangStmt_ExpressionTraitExprClass,
    ZigClangStmt_ExtVectorElementExprClass,
    ZigClangStmt_FixedPointLiteralClass,
    ZigClangStmt_FloatingLiteralClass,
    ZigClangStmt_ConstantExprClass,
    ZigClangStmt_ExprWithCleanupsClass,
    ZigClangStmt_FunctionParmPackExprClass,
    ZigClangStmt_GNUNullExprClass,
    ZigClangStmt_GenericSelectionExprClass,
    ZigClangStmt_ImaginaryLiteralClass,
    ZigClangStmt_ImplicitValueInitExprClass,
    ZigClangStmt_InitListExprClass,
    ZigClangStmt_IntegerLiteralClass,
    ZigClangStmt_LambdaExprClass,
    ZigClangStmt_MSPropertyRefExprClass,
    ZigClangStmt_MSPropertySubscriptExprClass,
    ZigClangStmt_MaterializeTemporaryExprClass,
    ZigClangStmt_MemberExprClass,
    ZigClangStmt_NoInitExprClass,
    ZigClangStmt_OMPArraySectionExprClass,
    ZigClangStmt_ObjCArrayLiteralClass,
    ZigClangStmt_ObjCAvailabilityCheckExprClass,
    ZigClangStmt_ObjCBoolLiteralExprClass,
    ZigClangStmt_ObjCBoxedExprClass,
    ZigClangStmt_ObjCDictionaryLiteralClass,
    ZigClangStmt_ObjCEncodeExprClass,
    ZigClangStmt_ObjCIndirectCopyRestoreExprClass,
    ZigClangStmt_ObjCIsaExprClass,
    ZigClangStmt_ObjCIvarRefExprClass,
    ZigClangStmt_ObjCMessageExprClass,
    ZigClangStmt_ObjCPropertyRefExprClass,
    ZigClangStmt_ObjCProtocolExprClass,
    ZigClangStmt_ObjCSelectorExprClass,
    ZigClangStmt_ObjCStringLiteralClass,
    ZigClangStmt_ObjCSubscriptRefExprClass,
    ZigClangStmt_OffsetOfExprClass,
    ZigClangStmt_OpaqueValueExprClass,
    ZigClangStmt_UnresolvedLookupExprClass,
    ZigClangStmt_UnresolvedMemberExprClass,
    ZigClangStmt_PackExpansionExprClass,
    ZigClangStmt_ParenExprClass,
    ZigClangStmt_ParenListExprClass,
    ZigClangStmt_PredefinedExprClass,
    ZigClangStmt_PseudoObjectExprClass,
    ZigClangStmt_ShuffleVectorExprClass,
    ZigClangStmt_SizeOfPackExprClass,
    ZigClangStmt_SourceLocExprClass,
    ZigClangStmt_StmtExprClass,
    ZigClangStmt_StringLiteralClass,
    ZigClangStmt_SubstNonTypeTemplateParmExprClass,
    ZigClangStmt_SubstNonTypeTemplateParmPackExprClass,
    ZigClangStmt_TypeTraitExprClass,
    ZigClangStmt_TypoExprClass,
    ZigClangStmt_UnaryExprOrTypeTraitExprClass,
    ZigClangStmt_UnaryOperatorClass,
    ZigClangStmt_VAArgExprClass,
    ZigClangStmt_LabelStmtClass,
    ZigClangStmt_WhileStmtClass,
};

enum ZigClangCK {
    ZigClangCK_Dependent,
    ZigClangCK_BitCast,
    ZigClangCK_LValueBitCast,
    ZigClangCK_LValueToRValueBitCast,
    ZigClangCK_LValueToRValue,
    ZigClangCK_NoOp,
    ZigClangCK_BaseToDerived,
    ZigClangCK_DerivedToBase,
    ZigClangCK_UncheckedDerivedToBase,
    ZigClangCK_Dynamic,
    ZigClangCK_ToUnion,
    ZigClangCK_ArrayToPointerDecay,
    ZigClangCK_FunctionToPointerDecay,
    ZigClangCK_NullToPointer,
    ZigClangCK_NullToMemberPointer,
    ZigClangCK_BaseToDerivedMemberPointer,
    ZigClangCK_DerivedToBaseMemberPointer,
    ZigClangCK_MemberPointerToBoolean,
    ZigClangCK_ReinterpretMemberPointer,
    ZigClangCK_UserDefinedConversion,
    ZigClangCK_ConstructorConversion,
    ZigClangCK_IntegralToPointer,
    ZigClangCK_PointerToIntegral,
    ZigClangCK_PointerToBoolean,
    ZigClangCK_ToVoid,
    ZigClangCK_VectorSplat,
    ZigClangCK_IntegralCast,
    ZigClangCK_IntegralToBoolean,
    ZigClangCK_IntegralToFloating,
    ZigClangCK_FixedPointCast,
    ZigClangCK_FixedPointToIntegral,
    ZigClangCK_IntegralToFixedPoint,
    ZigClangCK_FixedPointToBoolean,
    ZigClangCK_FloatingToIntegral,
    ZigClangCK_FloatingToBoolean,
    ZigClangCK_BooleanToSignedIntegral,
    ZigClangCK_FloatingCast,
    ZigClangCK_CPointerToObjCPointerCast,
    ZigClangCK_BlockPointerToObjCPointerCast,
    ZigClangCK_AnyPointerToBlockPointerCast,
    ZigClangCK_ObjCObjectLValueCast,
    ZigClangCK_FloatingRealToComplex,
    ZigClangCK_FloatingComplexToReal,
    ZigClangCK_FloatingComplexToBoolean,
    ZigClangCK_FloatingComplexCast,
    ZigClangCK_FloatingComplexToIntegralComplex,
    ZigClangCK_IntegralRealToComplex,
    ZigClangCK_IntegralComplexToReal,
    ZigClangCK_IntegralComplexToBoolean,
    ZigClangCK_IntegralComplexCast,
    ZigClangCK_IntegralComplexToFloatingComplex,
    ZigClangCK_ARCProduceObject,
    ZigClangCK_ARCConsumeObject,
    ZigClangCK_ARCReclaimReturnedObject,
    ZigClangCK_ARCExtendBlockObject,
    ZigClangCK_AtomicToNonAtomic,
    ZigClangCK_NonAtomicToAtomic,
    ZigClangCK_CopyAndAutoreleaseBlockObject,
    ZigClangCK_BuiltinFnToFnPtr,
    ZigClangCK_ZeroToOCLOpaqueType,
    ZigClangCK_AddressSpaceConversion,
    ZigClangCK_IntToOCLSampler,
};

enum ZigClangDeclKind {
    ZigClangDeclAccessSpec,
    ZigClangDeclBlock,
    ZigClangDeclCaptured,
    ZigClangDeclClassScopeFunctionSpecialization,
    ZigClangDeclEmpty,
    ZigClangDeclExport,
    ZigClangDeclExternCContext,
    ZigClangDeclFileScopeAsm,
    ZigClangDeclFriend,
    ZigClangDeclFriendTemplate,
    ZigClangDeclImport,
    ZigClangDeclLinkageSpec,
    ZigClangDeclLabel,
    ZigClangDeclNamespace,
    ZigClangDeclNamespaceAlias,
    ZigClangDeclObjCCompatibleAlias,
    ZigClangDeclObjCCategory,
    ZigClangDeclObjCCategoryImpl,
    ZigClangDeclObjCImplementation,
    ZigClangDeclObjCInterface,
    ZigClangDeclObjCProtocol,
    ZigClangDeclObjCMethod,
    ZigClangDeclObjCProperty,
    ZigClangDeclBuiltinTemplate,
    ZigClangDeclConcept,
    ZigClangDeclClassTemplate,
    ZigClangDeclFunctionTemplate,
    ZigClangDeclTypeAliasTemplate,
    ZigClangDeclVarTemplate,
    ZigClangDeclTemplateTemplateParm,
    ZigClangDeclEnum,
    ZigClangDeclRecord,
    ZigClangDeclCXXRecord,
    ZigClangDeclClassTemplateSpecialization,
    ZigClangDeclClassTemplatePartialSpecialization,
    ZigClangDeclTemplateTypeParm,
    ZigClangDeclObjCTypeParam,
    ZigClangDeclTypeAlias,
    ZigClangDeclTypedef,
    ZigClangDeclUnresolvedUsingTypename,
    ZigClangDeclUsing,
    ZigClangDeclUsingDirective,
    ZigClangDeclUsingPack,
    ZigClangDeclUsingShadow,
    ZigClangDeclConstructorUsingShadow,
    ZigClangDeclBinding,
    ZigClangDeclField,
    ZigClangDeclObjCAtDefsField,
    ZigClangDeclObjCIvar,
    ZigClangDeclFunction,
    ZigClangDeclCXXDeductionGuide,
    ZigClangDeclCXXMethod,
    ZigClangDeclCXXConstructor,
    ZigClangDeclCXXConversion,
    ZigClangDeclCXXDestructor,
    ZigClangDeclMSProperty,
    ZigClangDeclNonTypeTemplateParm,
    ZigClangDeclVar,
    ZigClangDeclDecomposition,
    ZigClangDeclImplicitParam,
    ZigClangDeclOMPCapturedExpr,
    ZigClangDeclParmVar,
    ZigClangDeclVarTemplateSpecialization,
    ZigClangDeclVarTemplatePartialSpecialization,
    ZigClangDeclEnumConstant,
    ZigClangDeclIndirectField,
    ZigClangDeclOMPDeclareMapper,
    ZigClangDeclOMPDeclareReduction,
    ZigClangDeclUnresolvedUsingValue,
    ZigClangDeclOMPAllocate,
    ZigClangDeclOMPRequires,
    ZigClangDeclOMPThreadPrivate,
    ZigClangDeclObjCPropertyImpl,
    ZigClangDeclPragmaComment,
    ZigClangDeclPragmaDetectMismatch,
    ZigClangDeclStaticAssert,
    ZigClangDeclTranslationUnit,
};

enum ZigClangBuiltinTypeKind {
    ZigClangBuiltinTypeOCLImage1dRO,
    ZigClangBuiltinTypeOCLImage1dArrayRO,
    ZigClangBuiltinTypeOCLImage1dBufferRO,
    ZigClangBuiltinTypeOCLImage2dRO,
    ZigClangBuiltinTypeOCLImage2dArrayRO,
    ZigClangBuiltinTypeOCLImage2dDepthRO,
    ZigClangBuiltinTypeOCLImage2dArrayDepthRO,
    ZigClangBuiltinTypeOCLImage2dMSAARO,
    ZigClangBuiltinTypeOCLImage2dArrayMSAARO,
    ZigClangBuiltinTypeOCLImage2dMSAADepthRO,
    ZigClangBuiltinTypeOCLImage2dArrayMSAADepthRO,
    ZigClangBuiltinTypeOCLImage3dRO,
    ZigClangBuiltinTypeOCLImage1dWO,
    ZigClangBuiltinTypeOCLImage1dArrayWO,
    ZigClangBuiltinTypeOCLImage1dBufferWO,
    ZigClangBuiltinTypeOCLImage2dWO,
    ZigClangBuiltinTypeOCLImage2dArrayWO,
    ZigClangBuiltinTypeOCLImage2dDepthWO,
    ZigClangBuiltinTypeOCLImage2dArrayDepthWO,
    ZigClangBuiltinTypeOCLImage2dMSAAWO,
    ZigClangBuiltinTypeOCLImage2dArrayMSAAWO,
    ZigClangBuiltinTypeOCLImage2dMSAADepthWO,
    ZigClangBuiltinTypeOCLImage2dArrayMSAADepthWO,
    ZigClangBuiltinTypeOCLImage3dWO,
    ZigClangBuiltinTypeOCLImage1dRW,
    ZigClangBuiltinTypeOCLImage1dArrayRW,
    ZigClangBuiltinTypeOCLImage1dBufferRW,
    ZigClangBuiltinTypeOCLImage2dRW,
    ZigClangBuiltinTypeOCLImage2dArrayRW,
    ZigClangBuiltinTypeOCLImage2dDepthRW,
    ZigClangBuiltinTypeOCLImage2dArrayDepthRW,
    ZigClangBuiltinTypeOCLImage2dMSAARW,
    ZigClangBuiltinTypeOCLImage2dArrayMSAARW,
    ZigClangBuiltinTypeOCLImage2dMSAADepthRW,
    ZigClangBuiltinTypeOCLImage2dArrayMSAADepthRW,
    ZigClangBuiltinTypeOCLImage3dRW,
    ZigClangBuiltinTypeOCLIntelSubgroupAVCMcePayload,
    ZigClangBuiltinTypeOCLIntelSubgroupAVCImePayload,
    ZigClangBuiltinTypeOCLIntelSubgroupAVCRefPayload,
    ZigClangBuiltinTypeOCLIntelSubgroupAVCSicPayload,
    ZigClangBuiltinTypeOCLIntelSubgroupAVCMceResult,
    ZigClangBuiltinTypeOCLIntelSubgroupAVCImeResult,
    ZigClangBuiltinTypeOCLIntelSubgroupAVCRefResult,
    ZigClangBuiltinTypeOCLIntelSubgroupAVCSicResult,
    ZigClangBuiltinTypeOCLIntelSubgroupAVCImeResultSingleRefStreamout,
    ZigClangBuiltinTypeOCLIntelSubgroupAVCImeResultDualRefStreamout,
    ZigClangBuiltinTypeOCLIntelSubgroupAVCImeSingleRefStreamin,
    ZigClangBuiltinTypeOCLIntelSubgroupAVCImeDualRefStreamin,
    ZigClangBuiltinTypeVoid,
    ZigClangBuiltinTypeBool,
    ZigClangBuiltinTypeChar_U,
    ZigClangBuiltinTypeUChar,
    ZigClangBuiltinTypeWChar_U,
    ZigClangBuiltinTypeChar8,
    ZigClangBuiltinTypeChar16,
    ZigClangBuiltinTypeChar32,
    ZigClangBuiltinTypeUShort,
    ZigClangBuiltinTypeUInt,
    ZigClangBuiltinTypeULong,
    ZigClangBuiltinTypeULongLong,
    ZigClangBuiltinTypeUInt128,
    ZigClangBuiltinTypeChar_S,
    ZigClangBuiltinTypeSChar,
    ZigClangBuiltinTypeWChar_S,
    ZigClangBuiltinTypeShort,
    ZigClangBuiltinTypeInt,
    ZigClangBuiltinTypeLong,
    ZigClangBuiltinTypeLongLong,
    ZigClangBuiltinTypeInt128,
    ZigClangBuiltinTypeShortAccum,
    ZigClangBuiltinTypeAccum,
    ZigClangBuiltinTypeLongAccum,
    ZigClangBuiltinTypeUShortAccum,
    ZigClangBuiltinTypeUAccum,
    ZigClangBuiltinTypeULongAccum,
    ZigClangBuiltinTypeShortFract,
    ZigClangBuiltinTypeFract,
    ZigClangBuiltinTypeLongFract,
    ZigClangBuiltinTypeUShortFract,
    ZigClangBuiltinTypeUFract,
    ZigClangBuiltinTypeULongFract,
    ZigClangBuiltinTypeSatShortAccum,
    ZigClangBuiltinTypeSatAccum,
    ZigClangBuiltinTypeSatLongAccum,
    ZigClangBuiltinTypeSatUShortAccum,
    ZigClangBuiltinTypeSatUAccum,
    ZigClangBuiltinTypeSatULongAccum,
    ZigClangBuiltinTypeSatShortFract,
    ZigClangBuiltinTypeSatFract,
    ZigClangBuiltinTypeSatLongFract,
    ZigClangBuiltinTypeSatUShortFract,
    ZigClangBuiltinTypeSatUFract,
    ZigClangBuiltinTypeSatULongFract,
    ZigClangBuiltinTypeHalf,
    ZigClangBuiltinTypeFloat,
    ZigClangBuiltinTypeDouble,
    ZigClangBuiltinTypeLongDouble,
    ZigClangBuiltinTypeFloat16,
    ZigClangBuiltinTypeFloat128,
    ZigClangBuiltinTypeNullPtr,
    ZigClangBuiltinTypeObjCId,
    ZigClangBuiltinTypeObjCClass,
    ZigClangBuiltinTypeObjCSel,
    ZigClangBuiltinTypeOCLSampler,
    ZigClangBuiltinTypeOCLEvent,
    ZigClangBuiltinTypeOCLClkEvent,
    ZigClangBuiltinTypeOCLQueue,
    ZigClangBuiltinTypeOCLReserveID,
    ZigClangBuiltinTypeDependent,
    ZigClangBuiltinTypeOverload,
    ZigClangBuiltinTypeBoundMember,
    ZigClangBuiltinTypePseudoObject,
    ZigClangBuiltinTypeUnknownAny,
    ZigClangBuiltinTypeBuiltinFn,
    ZigClangBuiltinTypeARCUnbridgedCast,
    ZigClangBuiltinTypeOMPArraySection,
};

enum ZigClangCallingConv {
    ZigClangCallingConv_C,           // __attribute__((cdecl))
    ZigClangCallingConv_X86StdCall,  // __attribute__((stdcall))
    ZigClangCallingConv_X86FastCall, // __attribute__((fastcall))
    ZigClangCallingConv_X86ThisCall, // __attribute__((thiscall))
    ZigClangCallingConv_X86VectorCall, // __attribute__((vectorcall))
    ZigClangCallingConv_X86Pascal,   // __attribute__((pascal))
    ZigClangCallingConv_Win64,       // __attribute__((ms_abi))
    ZigClangCallingConv_X86_64SysV,  // __attribute__((sysv_abi))
    ZigClangCallingConv_X86RegCall, // __attribute__((regcall))
    ZigClangCallingConv_AAPCS,       // __attribute__((pcs("aapcs")))
    ZigClangCallingConv_AAPCS_VFP,   // __attribute__((pcs("aapcs-vfp")))
    ZigClangCallingConv_IntelOclBicc, // __attribute__((intel_ocl_bicc))
    ZigClangCallingConv_SpirFunction, // default for OpenCL functions on SPIR target
    ZigClangCallingConv_OpenCLKernel, // inferred for OpenCL kernels
    ZigClangCallingConv_Swift,        // __attribute__((swiftcall))
    ZigClangCallingConv_PreserveMost, // __attribute__((preserve_most))
    ZigClangCallingConv_PreserveAll,  // __attribute__((preserve_all))
    ZigClangCallingConv_AArch64VectorCall, // __attribute__((aarch64_vector_pcs))
};

enum ZigClangStorageClass {
    // These are legal on both functions and variables.
    ZigClangStorageClass_None,
    ZigClangStorageClass_Extern,
    ZigClangStorageClass_Static,
    ZigClangStorageClass_PrivateExtern,

    // These are only legal on variables.
    ZigClangStorageClass_Auto,
    ZigClangStorageClass_Register,
};

/// IEEE-754R 4.3: Rounding-direction attributes.
enum ZigClangAPFloat_roundingMode {
    ZigClangAPFloat_roundingMode_NearestTiesToEven,
    ZigClangAPFloat_roundingMode_TowardPositive,
    ZigClangAPFloat_roundingMode_TowardNegative,
    ZigClangAPFloat_roundingMode_TowardZero,
    ZigClangAPFloat_roundingMode_NearestTiesToAway,
};

enum ZigClangStringLiteral_StringKind {
    ZigClangStringLiteral_StringKind_Ascii,
    ZigClangStringLiteral_StringKind_Wide,
    ZigClangStringLiteral_StringKind_UTF8,
    ZigClangStringLiteral_StringKind_UTF16,
    ZigClangStringLiteral_StringKind_UTF32,
};

enum ZigClangCharacterLiteral_CharacterKind {
    ZigClangCharacterLiteral_CharacterKind_Ascii,
    ZigClangCharacterLiteral_CharacterKind_Wide,
    ZigClangCharacterLiteral_CharacterKind_UTF8,
    ZigClangCharacterLiteral_CharacterKind_UTF16,
    ZigClangCharacterLiteral_CharacterKind_UTF32,
};

enum ZigClangVarDecl_TLSKind {
    ZigClangVarDecl_TLSKind_None,
    ZigClangVarDecl_TLSKind_Static,
    ZigClangVarDecl_TLSKind_Dynamic,
};

enum ZigClangElaboratedTypeKeyword {
    ZigClangETK_Struct,
    ZigClangETK_Interface,
    ZigClangETK_Union,
    ZigClangETK_Class,
    ZigClangETK_Enum,
    ZigClangETK_Typename,
    ZigClangETK_None,
};

enum ZigClangPreprocessedEntity_EntityKind {
    ZigClangPreprocessedEntity_InvalidKind,
    ZigClangPreprocessedEntity_MacroExpansionKind,
    ZigClangPreprocessedEntity_MacroDefinitionKind,
    ZigClangPreprocessedEntity_InclusionDirectiveKind,
};

enum ZigClangExpr_ConstExprUsage {
    ZigClangExpr_EvaluateForCodeGen,
    ZigClangExpr_EvaluateForMangling,
};

ZIG_EXTERN_C struct ZigClangSourceLocation ZigClangSourceManager_getSpellingLoc(const struct ZigClangSourceManager *,
        struct ZigClangSourceLocation Loc);
ZIG_EXTERN_C const char *ZigClangSourceManager_getFilename(const struct ZigClangSourceManager *,
        struct ZigClangSourceLocation SpellingLoc);
ZIG_EXTERN_C unsigned ZigClangSourceManager_getSpellingLineNumber(const struct ZigClangSourceManager *,
        struct ZigClangSourceLocation Loc);
ZIG_EXTERN_C unsigned ZigClangSourceManager_getSpellingColumnNumber(const struct ZigClangSourceManager *,
        struct ZigClangSourceLocation Loc);
ZIG_EXTERN_C const char* ZigClangSourceManager_getCharacterData(const struct ZigClangSourceManager *,
        struct ZigClangSourceLocation SL);

ZIG_EXTERN_C struct ZigClangQualType ZigClangASTContext_getPointerType(const struct ZigClangASTContext*, struct ZigClangQualType T);


// Can return null.
ZIG_EXTERN_C struct ZigClangASTUnit *ZigClangLoadFromCommandLine(const char **args_begin, const char **args_end,
        struct Stage2ErrorMsg **errors_ptr, size_t *errors_len, const char *resources_path);
ZIG_EXTERN_C void ZigClangASTUnit_delete(struct ZigClangASTUnit *);
ZIG_EXTERN_C void ZigClangErrorMsg_delete(struct Stage2ErrorMsg *ptr, size_t len);

ZIG_EXTERN_C struct ZigClangASTContext *ZigClangASTUnit_getASTContext(struct ZigClangASTUnit *);
ZIG_EXTERN_C struct ZigClangSourceManager *ZigClangASTUnit_getSourceManager(struct ZigClangASTUnit *);
ZIG_EXTERN_C bool ZigClangASTUnit_visitLocalTopLevelDecls(struct ZigClangASTUnit *, void *context,
    bool (*Fn)(void *context, const struct ZigClangDecl *decl));
ZIG_EXTERN_C struct ZigClangPreprocessingRecord_iterator ZigClangASTUnit_getLocalPreprocessingEntities_begin(struct ZigClangASTUnit *);
ZIG_EXTERN_C struct ZigClangPreprocessingRecord_iterator ZigClangASTUnit_getLocalPreprocessingEntities_end(struct ZigClangASTUnit *);

ZIG_EXTERN_C struct ZigClangPreprocessedEntity *ZigClangPreprocessingRecord_iterator_deref(
        struct ZigClangPreprocessingRecord_iterator);

ZIG_EXTERN_C enum ZigClangPreprocessedEntity_EntityKind ZigClangPreprocessedEntity_getKind(const struct ZigClangPreprocessedEntity *);

ZIG_EXTERN_C const struct ZigClangRecordDecl *ZigClangRecordType_getDecl(const struct ZigClangRecordType *record_ty);
ZIG_EXTERN_C const struct ZigClangEnumDecl *ZigClangEnumType_getDecl(const struct ZigClangEnumType *record_ty);

ZIG_EXTERN_C const struct ZigClangTagDecl *ZigClangRecordDecl_getCanonicalDecl(const struct ZigClangRecordDecl *record_decl);
ZIG_EXTERN_C const struct ZigClangTagDecl *ZigClangEnumDecl_getCanonicalDecl(const struct ZigClangEnumDecl *);
ZIG_EXTERN_C const struct ZigClangTypedefNameDecl *ZigClangTypedefNameDecl_getCanonicalDecl(const struct ZigClangTypedefNameDecl *);
ZIG_EXTERN_C const struct ZigClangFunctionDecl *ZigClangFunctionDecl_getCanonicalDecl(const ZigClangFunctionDecl *self);
ZIG_EXTERN_C const struct ZigClangVarDecl *ZigClangVarDecl_getCanonicalDecl(const ZigClangVarDecl *self);

ZIG_EXTERN_C const struct ZigClangRecordDecl *ZigClangRecordDecl_getDefinition(const struct ZigClangRecordDecl *);
ZIG_EXTERN_C const struct ZigClangEnumDecl *ZigClangEnumDecl_getDefinition(const struct ZigClangEnumDecl *);

ZIG_EXTERN_C struct ZigClangSourceLocation ZigClangRecordDecl_getLocation(const struct ZigClangRecordDecl *);
ZIG_EXTERN_C struct ZigClangSourceLocation ZigClangEnumDecl_getLocation(const struct ZigClangEnumDecl *);
ZIG_EXTERN_C struct ZigClangSourceLocation ZigClangTypedefNameDecl_getLocation(const struct ZigClangTypedefNameDecl *);
ZIG_EXTERN_C struct ZigClangSourceLocation ZigClangDecl_getLocation(const struct ZigClangDecl *);

ZIG_EXTERN_C struct ZigClangQualType ZigClangFunctionDecl_getType(const struct ZigClangFunctionDecl *);
ZIG_EXTERN_C struct ZigClangSourceLocation ZigClangFunctionDecl_getLocation(const struct ZigClangFunctionDecl *);
ZIG_EXTERN_C bool ZigClangFunctionDecl_hasBody(const struct ZigClangFunctionDecl *);
ZIG_EXTERN_C enum ZigClangStorageClass ZigClangFunctionDecl_getStorageClass(const struct ZigClangFunctionDecl *);
ZIG_EXTERN_C const struct ZigClangParmVarDecl *ZigClangFunctionDecl_getParamDecl(const struct ZigClangFunctionDecl *, unsigned i);
ZIG_EXTERN_C const struct ZigClangStmt *ZigClangFunctionDecl_getBody(const struct ZigClangFunctionDecl *);

ZIG_EXTERN_C bool ZigClangRecordDecl_isUnion(const struct ZigClangRecordDecl *record_decl);
ZIG_EXTERN_C bool ZigClangRecordDecl_isStruct(const struct ZigClangRecordDecl *record_decl);
ZIG_EXTERN_C bool ZigClangRecordDecl_isAnonymousStructOrUnion(const struct ZigClangRecordDecl *record_decl);
ZIG_EXTERN_C ZigClangRecordDecl_field_iterator ZigClangRecordDecl_field_begin(const struct ZigClangRecordDecl *);
ZIG_EXTERN_C ZigClangRecordDecl_field_iterator ZigClangRecordDecl_field_end(const struct ZigClangRecordDecl *);
ZIG_EXTERN_C ZigClangRecordDecl_field_iterator ZigClangRecordDecl_field_iterator_next(struct ZigClangRecordDecl_field_iterator);
ZIG_EXTERN_C const struct ZigClangFieldDecl * ZigClangRecordDecl_field_iterator_deref(struct ZigClangRecordDecl_field_iterator);
ZIG_EXTERN_C bool ZigClangRecordDecl_field_iterator_neq(
        struct ZigClangRecordDecl_field_iterator a,
        struct ZigClangRecordDecl_field_iterator b);

ZIG_EXTERN_C struct ZigClangQualType ZigClangEnumDecl_getIntegerType(const struct ZigClangEnumDecl *);
ZIG_EXTERN_C ZigClangEnumDecl_enumerator_iterator ZigClangEnumDecl_enumerator_begin(const struct ZigClangEnumDecl *);
ZIG_EXTERN_C ZigClangEnumDecl_enumerator_iterator ZigClangEnumDecl_enumerator_end(const struct ZigClangEnumDecl *);
ZIG_EXTERN_C ZigClangEnumDecl_enumerator_iterator ZigClangEnumDecl_enumerator_iterator_next(struct ZigClangEnumDecl_enumerator_iterator);
ZIG_EXTERN_C const struct ZigClangEnumConstantDecl * ZigClangEnumDecl_enumerator_iterator_deref(struct ZigClangEnumDecl_enumerator_iterator);
ZIG_EXTERN_C bool ZigClangEnumDecl_enumerator_iterator_neq(
        struct ZigClangEnumDecl_enumerator_iterator a,
        struct ZigClangEnumDecl_enumerator_iterator b);

ZIG_EXTERN_C const char *ZigClangDecl_getName_bytes_begin(const struct ZigClangDecl *decl);
ZIG_EXTERN_C enum ZigClangDeclKind ZigClangDecl_getKind(const struct ZigClangDecl *decl);
ZIG_EXTERN_C const char *ZigClangDecl_getDeclKindName(const struct ZigClangDecl *decl);

ZIG_EXTERN_C struct ZigClangQualType ZigClangVarDecl_getType(const struct ZigClangVarDecl *);
ZIG_EXTERN_C const struct ZigClangExpr *ZigClangVarDecl_getInit(const struct ZigClangVarDecl *var_decl);
ZIG_EXTERN_C enum ZigClangVarDecl_TLSKind ZigClangVarDecl_getTLSKind(const struct ZigClangVarDecl *var_decl);
ZIG_EXTERN_C struct ZigClangSourceLocation ZigClangVarDecl_getLocation(const struct ZigClangVarDecl *);
ZIG_EXTERN_C bool ZigClangVarDecl_hasExternalStorage(const struct ZigClangVarDecl *);
ZIG_EXTERN_C bool ZigClangVarDecl_isFileVarDecl(const struct ZigClangVarDecl *);
ZIG_EXTERN_C bool ZigClangVarDecl_hasInit(const struct ZigClangVarDecl *);
ZIG_EXTERN_C const struct ZigClangAPValue *ZigClangVarDecl_evaluateValue(const struct ZigClangVarDecl *);
ZIG_EXTERN_C struct ZigClangQualType ZigClangVarDecl_getTypeSourceInfo_getType(const struct ZigClangVarDecl *);
ZIG_EXTERN_C enum ZigClangStorageClass ZigClangVarDecl_getStorageClass(const struct ZigClangVarDecl *self);

ZIG_EXTERN_C bool ZigClangSourceLocation_eq(struct ZigClangSourceLocation a, struct ZigClangSourceLocation b);

ZIG_EXTERN_C const struct ZigClangTypedefNameDecl *ZigClangTypedefType_getDecl(const struct ZigClangTypedefType *);
ZIG_EXTERN_C struct ZigClangQualType ZigClangTypedefNameDecl_getUnderlyingType(const struct ZigClangTypedefNameDecl *);

ZIG_EXTERN_C struct ZigClangQualType ZigClangQualType_getCanonicalType(struct ZigClangQualType);
ZIG_EXTERN_C const struct ZigClangType *ZigClangQualType_getTypePtr(struct ZigClangQualType);
ZIG_EXTERN_C enum ZigClangTypeClass ZigClangQualType_getTypeClass(struct ZigClangQualType);
ZIG_EXTERN_C void ZigClangQualType_addConst(struct ZigClangQualType *);
ZIG_EXTERN_C bool ZigClangQualType_eq(struct ZigClangQualType, struct ZigClangQualType);
ZIG_EXTERN_C bool ZigClangQualType_isConstQualified(struct ZigClangQualType);
ZIG_EXTERN_C bool ZigClangQualType_isVolatileQualified(struct ZigClangQualType);
ZIG_EXTERN_C bool ZigClangQualType_isRestrictQualified(struct ZigClangQualType);

ZIG_EXTERN_C enum ZigClangTypeClass ZigClangType_getTypeClass(const struct ZigClangType *self);
ZIG_EXTERN_C struct ZigClangQualType ZigClangType_getPointeeType(const struct ZigClangType *self);
ZIG_EXTERN_C bool ZigClangType_isVoidType(const struct ZigClangType *self);
ZIG_EXTERN_C const char *ZigClangType_getTypeClassName(const struct ZigClangType *self);
ZIG_EXTERN_C const struct ZigClangArrayType *ZigClangType_getAsArrayTypeUnsafe(const struct ZigClangType *self);

ZIG_EXTERN_C struct ZigClangSourceLocation ZigClangStmt_getBeginLoc(const struct ZigClangStmt *self);
ZIG_EXTERN_C enum ZigClangStmtClass ZigClangStmt_getStmtClass(const struct ZigClangStmt *self);
ZIG_EXTERN_C bool ZigClangStmt_classof_Expr(const struct ZigClangStmt *self);

ZIG_EXTERN_C enum ZigClangStmtClass ZigClangExpr_getStmtClass(const struct ZigClangExpr *self);
ZIG_EXTERN_C struct ZigClangQualType ZigClangExpr_getType(const struct ZigClangExpr *self);
ZIG_EXTERN_C struct ZigClangSourceLocation ZigClangExpr_getBeginLoc(const struct ZigClangExpr *self);
ZIG_EXTERN_C bool ZigClangExpr_EvaluateAsBooleanCondition(const struct ZigClangExpr *self,
        bool *result, const struct ZigClangASTContext *ctx, bool in_constant_context);
ZIG_EXTERN_C bool ZigClangExpr_EvaluateAsFloat(const struct ZigClangExpr *self,
        ZigClangAPFloat **result, const struct ZigClangASTContext *ctx);
ZIG_EXTERN_C bool ZigClangExpr_EvaluateAsConstantExpr(const struct ZigClangExpr *,
        struct ZigClangExprEvalResult *, ZigClangExpr_ConstExprUsage, const struct ZigClangASTContext *);

ZIG_EXTERN_C const ZigClangExpr *ZigClangInitListExpr_getInit(const ZigClangInitListExpr *, unsigned);
ZIG_EXTERN_C const ZigClangExpr *ZigClangInitListExpr_getArrayFiller(const ZigClangInitListExpr *);
ZIG_EXTERN_C unsigned ZigClangInitListExpr_getNumInits(const ZigClangInitListExpr *);

ZIG_EXTERN_C enum ZigClangAPValueKind ZigClangAPValue_getKind(const struct ZigClangAPValue *self);
ZIG_EXTERN_C const struct ZigClangAPSInt *ZigClangAPValue_getInt(const struct ZigClangAPValue *self);
ZIG_EXTERN_C unsigned ZigClangAPValue_getArrayInitializedElts(const struct ZigClangAPValue *self);
ZIG_EXTERN_C const struct ZigClangAPValue *ZigClangAPValue_getArrayInitializedElt(const struct ZigClangAPValue *self, unsigned i);
ZIG_EXTERN_C const struct ZigClangAPValue *ZigClangAPValue_getArrayFiller(const struct ZigClangAPValue *self);
ZIG_EXTERN_C unsigned ZigClangAPValue_getArraySize(const struct ZigClangAPValue *self);
ZIG_EXTERN_C struct ZigClangAPValueLValueBase ZigClangAPValue_getLValueBase(const struct ZigClangAPValue *self);

ZIG_EXTERN_C bool ZigClangAPSInt_isSigned(const struct ZigClangAPSInt *self);
ZIG_EXTERN_C bool ZigClangAPSInt_isNegative(const struct ZigClangAPSInt *self);
ZIG_EXTERN_C const struct ZigClangAPSInt *ZigClangAPSInt_negate(const struct ZigClangAPSInt *self);
ZIG_EXTERN_C void ZigClangAPSInt_free(const struct ZigClangAPSInt *self);
ZIG_EXTERN_C const uint64_t *ZigClangAPSInt_getRawData(const struct ZigClangAPSInt *self);
ZIG_EXTERN_C unsigned ZigClangAPSInt_getNumWords(const struct ZigClangAPSInt *self);

ZIG_EXTERN_C uint64_t ZigClangAPInt_getLimitedValue(const struct ZigClangAPInt *self, uint64_t limit);

ZIG_EXTERN_C const struct ZigClangExpr *ZigClangAPValueLValueBase_dyn_cast_Expr(struct ZigClangAPValueLValueBase self);

ZIG_EXTERN_C enum ZigClangBuiltinTypeKind ZigClangBuiltinType_getKind(const struct ZigClangBuiltinType *self);

ZIG_EXTERN_C bool ZigClangFunctionType_getNoReturnAttr(const struct ZigClangFunctionType *self);
ZIG_EXTERN_C enum ZigClangCallingConv ZigClangFunctionType_getCallConv(const struct ZigClangFunctionType *self);
ZIG_EXTERN_C struct ZigClangQualType ZigClangFunctionType_getReturnType(const struct ZigClangFunctionType *self);

ZIG_EXTERN_C bool ZigClangFunctionProtoType_isVariadic(const struct ZigClangFunctionProtoType *self);
ZIG_EXTERN_C unsigned ZigClangFunctionProtoType_getNumParams(const struct ZigClangFunctionProtoType *self);
ZIG_EXTERN_C struct ZigClangQualType ZigClangFunctionProtoType_getParamType(const struct ZigClangFunctionProtoType *self, unsigned i);
ZIG_EXTERN_C struct ZigClangQualType ZigClangFunctionProtoType_getReturnType(const struct ZigClangFunctionProtoType *self);


ZIG_EXTERN_C ZigClangCompoundStmt_const_body_iterator ZigClangCompoundStmt_body_begin(const struct ZigClangCompoundStmt *self);
ZIG_EXTERN_C ZigClangCompoundStmt_const_body_iterator ZigClangCompoundStmt_body_end(const struct ZigClangCompoundStmt *self);

ZIG_EXTERN_C ZigClangDeclStmt_const_decl_iterator ZigClangDeclStmt_decl_begin(const struct ZigClangDeclStmt *self);
ZIG_EXTERN_C ZigClangDeclStmt_const_decl_iterator ZigClangDeclStmt_decl_end(const struct ZigClangDeclStmt *self);
ZIG_EXTERN_C struct ZigClangSourceLocation ZigClangDeclStmt_getBeginLoc(const struct ZigClangDeclStmt *self);

ZIG_EXTERN_C unsigned ZigClangAPFloat_convertToHexString(const struct ZigClangAPFloat *self, char *DST,
        unsigned HexDigits, bool UpperCase, enum ZigClangAPFloat_roundingMode RM);
ZIG_EXTERN_C double ZigClangAPFloat_getValueAsApproximateDouble(const ZigClangFloatingLiteral *self);

ZIG_EXTERN_C enum ZigClangStringLiteral_StringKind ZigClangStringLiteral_getKind(const struct ZigClangStringLiteral *self);
ZIG_EXTERN_C const char *ZigClangStringLiteral_getString_bytes_begin_size(const struct ZigClangStringLiteral *self,
        size_t *len);

ZIG_EXTERN_C const struct ZigClangStringLiteral *ZigClangPredefinedExpr_getFunctionName(
        const struct ZigClangPredefinedExpr *self);

ZIG_EXTERN_C struct ZigClangSourceLocation ZigClangImplicitCastExpr_getBeginLoc(const struct ZigClangImplicitCastExpr *);
ZIG_EXTERN_C enum ZigClangCK ZigClangImplicitCastExpr_getCastKind(const struct ZigClangImplicitCastExpr *);
ZIG_EXTERN_C const struct ZigClangExpr *ZigClangImplicitCastExpr_getSubExpr(const struct ZigClangImplicitCastExpr *);

ZIG_EXTERN_C struct ZigClangQualType ZigClangArrayType_getElementType(const struct ZigClangArrayType *);

ZIG_EXTERN_C struct ZigClangQualType ZigClangIncompleteArrayType_getElementType(const struct ZigClangIncompleteArrayType *);

ZIG_EXTERN_C struct ZigClangQualType ZigClangConstantArrayType_getElementType(const struct ZigClangConstantArrayType *);
ZIG_EXTERN_C const struct ZigClangAPInt *ZigClangConstantArrayType_getSize(const struct ZigClangConstantArrayType *);

ZIG_EXTERN_C const struct ZigClangValueDecl *ZigClangDeclRefExpr_getDecl(const struct ZigClangDeclRefExpr *);
ZIG_EXTERN_C const struct ZigClangNamedDecl *ZigClangDeclRefExpr_getFoundDecl(const struct ZigClangDeclRefExpr *);

ZIG_EXTERN_C struct ZigClangQualType ZigClangParenType_getInnerType(const struct ZigClangParenType *);

ZIG_EXTERN_C struct ZigClangQualType ZigClangAttributedType_getEquivalentType(const struct ZigClangAttributedType *);

ZIG_EXTERN_C struct ZigClangQualType ZigClangMacroQualifiedType_getModifiedType(const struct ZigClangMacroQualifiedType *);

ZIG_EXTERN_C struct ZigClangQualType ZigClangElaboratedType_getNamedType(const struct ZigClangElaboratedType *);
ZIG_EXTERN_C enum ZigClangElaboratedTypeKeyword ZigClangElaboratedType_getKeyword(const struct ZigClangElaboratedType *);

ZIG_EXTERN_C struct ZigClangSourceLocation ZigClangCStyleCastExpr_getBeginLoc(const struct ZigClangCStyleCastExpr *);
ZIG_EXTERN_C const struct ZigClangExpr *ZigClangCStyleCastExpr_getSubExpr(const struct ZigClangCStyleCastExpr *);
ZIG_EXTERN_C struct ZigClangQualType ZigClangCStyleCastExpr_getType(const struct ZigClangCStyleCastExpr *);

ZIG_EXTERN_C bool ZigClangIntegerLiteral_EvaluateAsInt(const struct ZigClangIntegerLiteral *, struct ZigClangExprEvalResult *, const struct ZigClangASTContext *);
ZIG_EXTERN_C struct ZigClangSourceLocation ZigClangIntegerLiteral_getBeginLoc(const struct ZigClangIntegerLiteral *);

ZIG_EXTERN_C const struct ZigClangExpr *ZigClangReturnStmt_getRetValue(const struct ZigClangReturnStmt *);

ZIG_EXTERN_C enum ZigClangBO ZigClangBinaryOperator_getOpcode(const struct ZigClangBinaryOperator *);
ZIG_EXTERN_C struct ZigClangSourceLocation ZigClangBinaryOperator_getBeginLoc(const struct ZigClangBinaryOperator *);
ZIG_EXTERN_C const struct ZigClangExpr *ZigClangBinaryOperator_getLHS(const struct ZigClangBinaryOperator *);
ZIG_EXTERN_C const struct ZigClangExpr *ZigClangBinaryOperator_getRHS(const struct ZigClangBinaryOperator *);
ZIG_EXTERN_C struct ZigClangQualType ZigClangBinaryOperator_getType(const struct ZigClangBinaryOperator *);

ZIG_EXTERN_C struct ZigClangQualType ZigClangDecayedType_getDecayedType(const struct ZigClangDecayedType *);

ZIG_EXTERN_C const struct ZigClangCompoundStmt *ZigClangStmtExpr_getSubStmt(const struct ZigClangStmtExpr *);

ZIG_EXTERN_C struct ZigClangSourceLocation ZigClangCharacterLiteral_getBeginLoc(const struct ZigClangCharacterLiteral *);
ZIG_EXTERN_C enum ZigClangCharacterLiteral_CharacterKind ZigClangCharacterLiteral_getKind(const struct ZigClangCharacterLiteral *);
ZIG_EXTERN_C unsigned ZigClangCharacterLiteral_getValue(const struct ZigClangCharacterLiteral *);

ZIG_EXTERN_C const struct ZigClangExpr *ZigClangConditionalOperator_getCond(const struct ZigClangConditionalOperator *);
ZIG_EXTERN_C const struct ZigClangExpr *ZigClangConditionalOperator_getTrueExpr(const struct ZigClangConditionalOperator *);
ZIG_EXTERN_C const struct ZigClangExpr *ZigClangConditionalOperator_getFalseExpr(const struct ZigClangConditionalOperator *);

ZIG_EXTERN_C struct ZigClangQualType ZigClangCompoundAssignOperator_getType(const struct ZigClangCompoundAssignOperator *);
ZIG_EXTERN_C struct ZigClangQualType ZigClangCompoundAssignOperator_getComputationLHSType(const struct ZigClangCompoundAssignOperator *);
ZIG_EXTERN_C struct ZigClangQualType ZigClangCompoundAssignOperator_getComputationResultType(const struct ZigClangCompoundAssignOperator *);
ZIG_EXTERN_C struct ZigClangSourceLocation ZigClangCompoundAssignOperator_getBeginLoc(const struct ZigClangCompoundAssignOperator *);
ZIG_EXTERN_C enum ZigClangBO ZigClangCompoundAssignOperator_getOpcode(const struct ZigClangCompoundAssignOperator *);
ZIG_EXTERN_C const struct ZigClangExpr *ZigClangCompoundAssignOperator_getLHS(const struct ZigClangCompoundAssignOperator *);
ZIG_EXTERN_C const struct ZigClangExpr *ZigClangCompoundAssignOperator_getRHS(const struct ZigClangCompoundAssignOperator *);

ZIG_EXTERN_C enum ZigClangUO ZigClangUnaryOperator_getOpcode(const struct ZigClangUnaryOperator *);
ZIG_EXTERN_C struct ZigClangQualType ZigClangUnaryOperator_getType(const struct ZigClangUnaryOperator *);
ZIG_EXTERN_C const struct ZigClangExpr *ZigClangUnaryOperator_getSubExpr(const struct ZigClangUnaryOperator *);
ZIG_EXTERN_C struct ZigClangSourceLocation ZigClangUnaryOperator_getBeginLoc(const struct ZigClangUnaryOperator *);

ZIG_EXTERN_C const struct ZigClangExpr *ZigClangWhileStmt_getCond(const struct ZigClangWhileStmt *);
ZIG_EXTERN_C const struct ZigClangStmt *ZigClangWhileStmt_getBody(const struct ZigClangWhileStmt *);

ZIG_EXTERN_C const struct ZigClangStmt *ZigClangIfStmt_getThen(const struct ZigClangIfStmt *);
ZIG_EXTERN_C const struct ZigClangStmt *ZigClangIfStmt_getElse(const struct ZigClangIfStmt *);
ZIG_EXTERN_C const struct ZigClangExpr *ZigClangIfStmt_getCond(const struct ZigClangIfStmt *);

ZIG_EXTERN_C const struct ZigClangExpr *ZigClangCallExpr_getCallee(const struct ZigClangCallExpr *);
ZIG_EXTERN_C unsigned ZigClangCallExpr_getNumArgs(const struct ZigClangCallExpr *);
ZIG_EXTERN_C const struct ZigClangExpr * const * ZigClangCallExpr_getArgs(const struct ZigClangCallExpr *);

ZIG_EXTERN_C const struct ZigClangExpr *ZigClangMemberExpr_getBase(const struct ZigClangMemberExpr *);
ZIG_EXTERN_C bool ZigClangMemberExpr_isArrow(const struct ZigClangMemberExpr *);
ZIG_EXTERN_C const struct ZigClangValueDecl * ZigClangMemberExpr_getMemberDecl(const struct ZigClangMemberExpr *);

ZIG_EXTERN_C const struct ZigClangExpr *ZigClangArraySubscriptExpr_getBase(const struct ZigClangArraySubscriptExpr *);
ZIG_EXTERN_C const struct ZigClangExpr *ZigClangArraySubscriptExpr_getIdx(const struct ZigClangArraySubscriptExpr *);

ZIG_EXTERN_C struct ZigClangQualType ZigClangUnaryExprOrTypeTraitExpr_getTypeOfArgument(const struct ZigClangUnaryExprOrTypeTraitExpr *);
ZIG_EXTERN_C struct ZigClangSourceLocation ZigClangUnaryExprOrTypeTraitExpr_getBeginLoc(const struct ZigClangUnaryExprOrTypeTraitExpr *);

ZIG_EXTERN_C const struct ZigClangStmt *ZigClangDoStmt_getBody(const struct ZigClangDoStmt *);
ZIG_EXTERN_C const struct ZigClangExpr *ZigClangDoStmt_getCond(const struct ZigClangDoStmt *);

ZIG_EXTERN_C const struct ZigClangStmt *ZigClangForStmt_getInit(const struct ZigClangForStmt *);
ZIG_EXTERN_C const struct ZigClangExpr *ZigClangForStmt_getCond(const struct ZigClangForStmt *);
ZIG_EXTERN_C const struct ZigClangExpr *ZigClangForStmt_getInc(const struct ZigClangForStmt *);
ZIG_EXTERN_C const struct ZigClangStmt *ZigClangForStmt_getBody(const struct ZigClangForStmt *);

ZIG_EXTERN_C const struct ZigClangDeclStmt *ZigClangSwitchStmt_getConditionVariableDeclStmt(const struct ZigClangSwitchStmt *);
ZIG_EXTERN_C const struct ZigClangExpr *ZigClangSwitchStmt_getCond(const struct ZigClangSwitchStmt *);
ZIG_EXTERN_C const struct ZigClangStmt *ZigClangSwitchStmt_getBody(const struct ZigClangSwitchStmt *);
ZIG_EXTERN_C bool ZigClangSwitchStmt_isAllEnumCasesCovered(const struct ZigClangSwitchStmt *);

ZIG_EXTERN_C const struct ZigClangExpr *ZigClangCaseStmt_getLHS(const struct ZigClangCaseStmt *);
ZIG_EXTERN_C const struct ZigClangExpr *ZigClangCaseStmt_getRHS(const struct ZigClangCaseStmt *);
ZIG_EXTERN_C struct ZigClangSourceLocation ZigClangCaseStmt_getBeginLoc(const struct ZigClangCaseStmt *);
ZIG_EXTERN_C const struct ZigClangStmt *ZigClangCaseStmt_getSubStmt(const struct ZigClangCaseStmt *);

ZIG_EXTERN_C const struct ZigClangStmt *ZigClangDefaultStmt_getSubStmt(const struct ZigClangDefaultStmt *);

ZIG_EXTERN_C const struct ZigClangExpr *ZigClangParenExpr_getSubExpr(const struct ZigClangParenExpr *);

ZIG_EXTERN_C const char *ZigClangMacroDefinitionRecord_getName_getNameStart(const struct ZigClangMacroDefinitionRecord *);
ZIG_EXTERN_C struct ZigClangSourceLocation ZigClangMacroDefinitionRecord_getSourceRange_getBegin(const struct ZigClangMacroDefinitionRecord *);
ZIG_EXTERN_C struct ZigClangSourceLocation ZigClangMacroDefinitionRecord_getSourceRange_getEnd(const struct ZigClangMacroDefinitionRecord *);

ZIG_EXTERN_C bool ZigClangFieldDecl_isBitField(const struct ZigClangFieldDecl *);
ZIG_EXTERN_C struct ZigClangQualType ZigClangFieldDecl_getType(const struct ZigClangFieldDecl *);
ZIG_EXTERN_C struct ZigClangSourceLocation ZigClangFieldDecl_getLocation(const struct ZigClangFieldDecl *);

ZIG_EXTERN_C const struct ZigClangExpr *ZigClangEnumConstantDecl_getInitExpr(const struct ZigClangEnumConstantDecl *);
ZIG_EXTERN_C const struct ZigClangAPSInt *ZigClangEnumConstantDecl_getInitVal(const struct ZigClangEnumConstantDecl *);
#endif
