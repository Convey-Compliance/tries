unit uAllocators;

interface

{$i DelphiVersion_defines.inc}

const
  MAX_MEDIUM_BLOCK_SIZE = 256 * 1024;
  Aligner = sizeof (NativeUInt) - 1;
  MAGIC_NUMBER = $73737300;

type
  PPage = ^TPage;
  PBlock = ^TBlock;
  TBlockHeader = record
    PagePointer : PPage;
    {$IFDef OVERALLOC}
    MagicNumber : NativeUInt;
    {$ENDIF}
  end;
  TBlock = record
    Header : TBlockHeader;
    Data : array [0..MaxInt - sizeof(PPage) - sizeof(NativeUInt) - 16] of byte;
  end;
  TPageHeader = record
    RefCount : NativeUInt;
  end;
  TPage = record
    Header : TPageHeader;
    FirstBlock : TBlock;
  end;

  {$IFNDEF DELPHI2009}
  NativeUInt = Cardinal;
  {$ENDIF}

  TBlockEvent = procedure(ABlockPtr : Pointer) of object;
  TFastHeap = class
  private
    function GetCurrentBlockRefCount: Integer;
  protected
    FStartBlockArray : Pointer;
    FNextOffset : NativeUInt;
    FPageSize: NativeUInt;
    FTotalUsableSize : NativeUInt;
    FOnAllocBlock : TBlockEvent;
    FOnDeallocBlock : TBlockEvent;
    procedure AllocateMemory(var APtr: Pointer; ASize: NativeUInt);
    procedure AllocNewBlockArray;
    procedure DeallocateMemory(APtr: Pointer);
  public
    destructor Destroy; override;
    procedure DeAlloc(Ptr: Pointer);
    property CurrentBlockRefCount: Integer read GetCurrentBlockRefCount;
    property OnAllocBlock : TBlockEvent read FOnAllocBlock write FOnAllocBlock;
    property OnDeallocBlock : TBlockEvent read FOnDeallocBlock write FOnDeallocBlock;
  end;

  TFixedBlockHeap = class(TFastHeap)
  protected
    FBlockSize : NativeUInt;
    FOriginalBlockSize: NativeUInt;
  public
    constructor Create(ABlockSize, ABlockCount: NativeUInt); overload;
    constructor Create(AClass: TClass; ABlockCount: NativeUInt); overload;
    function Alloc: Pointer;
    property OriginalBlockSize: NativeUInt read FOriginalBlockSize;
  end;

  TVariableBlockHeap = class(TFastHeap)
  public
    constructor Create(APoolSize: NativeUInt);
    function Alloc(ASize: NativeUInt): Pointer;
  end;

function DeAlloc(Ptr: Pointer) : Boolean;
function _GetMem(ASize: NativeUInt): Pointer;
procedure _FreeMem(Ptr : pointer);

implementation

{$IFDEF USEFASTMM4}
  {$IFDEF WIN64}
  This configuration is not supported
  {$ENDIF}
{$ENDIF}

uses
  SysUtils {$IFDEF USEFASTMM4} ,FastMM4 {$ENDIF}{$IFDEF DELPHIXE2} ,Types {$ENDIF};

procedure _FreeMem(Ptr : pointer);
{$IFDEF USEFASTMM4}
asm
  {$IfDef FullDebugMode}
  jmp DebugFreeMem
  {$Else}
  jmp FastFreeMem
  {$Endif}
{$ELSE}
begin
  FreeMem(Ptr);
{$ENDIF}
end;

function _GetMem(ASize: NativeUInt): Pointer;
{$IFDEF USEFASTMM4}
asm
  {$IfDef FullDebugMode}
  jmp DebugGetMem
  {$ELSE}
  jmp FastGetMem
  {$ENDIF}
{$ELSE}
begin
  GetMem(Result, ASize);
{$ENDIF}
end;

function DeAlloc(Ptr: Pointer) : boolean;
{$IfNDef MEMLEAKPROFILING}
asm
  {$IFDEF WIN64}
  mov rcx, qword ptr [rcx - offset TBlock.Data + offset TBlock.Header.PagePointer] // Move to RAX pointer to start of block
  sub qword ptr [rcx + TPage.Header.RefCount], 1 // Decrement by one reference counter of block
  jnz @@Return // If zero flag was set, means reference counter reached zero if not then return no further action
  sub rsp, 20h
  call _FreeMem
  add rsp, 20h
  mov rax, True
  ret
@@Return:
  mov rax, False
  {$ELSE}
  mov eax, dword ptr [eax - offset TBlock.Data + offset TBlock.Header.PagePointer] // Move to EAX pointer to start of block
  sub dword ptr [eax + TPage.Header.RefCount], 1 // Decrement by one reference counter of block
  jnz @@Return // If zero flag was set, means reference counter reached zero if not then return no further action
  call _FreeMem
  mov eax, True
  ret
@@Return:
  mov eax, False
  {$ENDIF}
{$Else}
begin
  FreeMem(Ptr);
{$EndIf}
end;

{ TFastHeap }

function AllocBlockInPage(APage: Pointer; AOffset: NativeUInt): Pointer; inline;
begin
  Result := Pointer (NativeUInt(APage) + AOffset);
  PBlock(Result).Header.PagePointer := APage;
  {$IFDef OVERALLOC}
  PBlock(Result).Header.MagicNumber := MAGIC_NUMBER;
  {$ENDIF}
  inc (PPage(APage).Header.RefCount);
  Result := @PBlock(Result).Data;
end;

destructor TFastHeap.Destroy;
begin
  if FStartBlockArray <> nil then
    begin
      dec (PPage(FStartBlockArray).Header.RefCount);
      if PPage(FStartBlockArray).Header.RefCount <= 0
        then DeallocateMemory(FStartBlockArray);
    end;
  inherited;
end;

procedure TFastHeap.AllocNewBlockArray;
begin
  if (FStartBlockArray <> nil) and (PPage(FStartBlockArray).Header.RefCount = 1)
    then FNextOffset := sizeof (TPageHeader)
    else
    begin
      if FStartBlockArray <> nil
        then dec (PPage(FStartBlockArray).Header.RefCount);
      AllocateMemory(FStartBlockArray, FPageSize);
      PPage(FStartBlockArray).Header.RefCount := 1;
      FNextOffset := sizeof (TPageHeader);
    end;
end;

procedure TFastHeap.DeAlloc(Ptr: Pointer);
begin
  if uAllocators.DeAlloc(Ptr) and assigned(FOnDeallocBlock) then
    FOnDeallocBlock(Ptr);
end;

procedure TFastHeap.AllocateMemory(var APtr: Pointer; ASize: NativeUInt);
begin
  APtr := _GetMem(ASize);
  if assigned(OnAllocBlock)
    then OnAllocBlock(APtr);
end;

procedure TFastHeap.DeallocateMemory(APtr: Pointer);
begin
  if assigned(OnDeallocBlock) then
    OnDeallocBlock(APtr);
  _FreeMem(APtr);
end;

function TFastHeap.GetCurrentBlockRefCount: Integer;
begin
  Result := PPage(FStartBlockArray).Header.RefCount;
end;

{ TFixedBlockHeap }

constructor TFixedBlockHeap.Create(ABlockSize, ABlockCount: NativeUInt);
begin
  inherited Create;
  FOriginalBlockSize := ABlockSize;
  FBlockSize := (ABlockSize + sizeof(TBlockHeader) + Aligner) and (not Aligner);
  FTotalUsableSize := FBlockSize * ABlockCount;
  FPageSize := FTotalUsableSize + sizeof (TPageHeader);
  FNextOffset := FPageSize;
end;

constructor TFixedBlockHeap.Create(AClass: TClass; ABlockCount: NativeUInt);
begin
  Create (AClass.InstanceSize, ABlockCount);
end;

function TFixedBlockHeap.Alloc: Pointer;
begin
  {$IfNDef MEMLEAKPROFILING}
  if FNextOffset >= FPageSize
    then AllocNewBlockArray;
  Result := AllocBlockInPage(FStartBlockArray, FNextOffset);
  inc (FNextOffset, FBlockSize);
  {$Else}
  GetMem(result, FBlockSize);
  {$EndIf}
end;

{ TVariableBlockHeap }

constructor TVariableBlockHeap.Create(APoolSize: NativeUInt);
begin
  inherited Create;
  FTotalUsableSize := (APoolSize + Aligner) and (not Aligner);
  FPageSize := FTotalUsableSize + sizeof (TPageHeader);
  FNextOffset := FPageSize;
end;

function TVariableBlockHeap.Alloc(ASize: NativeUInt): Pointer;
begin
  {$IfNDef MEMLEAKPROFILING}
  ASize := (ASize + sizeof (TBlockHeader) + Aligner) and (not Aligner); // Align size to native word size bits
  if ASize <= FTotalUsableSize
    then
    begin
      if FNextOffset + ASize >= FPageSize
        then AllocNewBlockArray;
      Result := AllocBlockInPage(FStartBlockArray, FNextOffset);
      inc (FNextOffset, ASize);
    end
    else
    begin
      AllocateMemory(Result, sizeof(TPageHeader) + ASize);
      PPage(Result).Header.RefCount := 0;
      Result := AllocBlockInPage(PPage(Result), sizeof(TPageHeader));
    end;
  {$Else}
  GetMem(result, ASize);
  {$EndIf}
end;

end.

