#!/usr/bin/env python3
"""Regenera el proyecto Xcode a partir de las fuentes y recursos versionados.

Uso:
    python3 scripts/generate_project.py            escribe el proyecto
    python3 scripts/generate_project.py --check     no escribe nada; devuelve 1 si
                                                    el proyecto en disco está
                                                    desactualizado, y dice por qué

INVARIANTE: la generación es DETERMINISTA. Los UID se derivan de sha1 del nombre
y las listas de fuentes se construyen con sorted(rglob(...)). El modo --check
depende de eso: cualquier cambio futuro que introduzca orden de diccionario no
determinista, marcas de tiempo o UUID aleatorios lo rompe. Ver
docs/specs/C8-pbxproj-sincronizado.md.
"""
from pathlib import Path
import hashlib
import json
import re
import sys

# FUENTE DE VERDAD de la versión del producto. Todo lo demás la deriva:
#   - MARKETING_VERSION / CURRENT_PROJECT_VERSION del target
#   - CFBundleShortVersionString / CFBundleVersion del Info.plist, que ya usan
#     $(MARKETING_VERSION) y $(CURRENT_PROJECT_VERSION)
#   - el clientInfo que la app envía a Codex, que lo lee del bundle en runtime
# El README no repite el número a propósito: así no hay nada que pueda quedar
# desincronizado. Ver docs/specs/C10-version-unica.md.
MARKETING_VERSION = '0.5.4'
BUILD_NUMBER = '24'

root = Path(__file__).resolve().parent.parent
PBXPROJ = root / 'Braket.xcodeproj/project.pbxproj'
SCHEME = root / 'Braket.xcodeproj/xcshareddata/xcschemes/Braket.xcscheme'

def uid(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()

def q(value):
    return json.dumps(str(value))

def swift_sources():
    """Las fuentes que el proyecto debe contener, en orden determinista."""
    return (sorted((root / 'Krabzik').rglob('*.swift')),
            sorted((root / 'KrabzikTests').rglob('*.swift')))

def render():
    """Devuelve (pbxproj, scheme) como texto, sin escribir nada."""
    objects = []

    def obj(name, body):
        objects.append(f'{uid(name)} = {{ {body} }};')
        return uid(name)

    app_sources, test_sources = swift_sources()
    notices = 'Krabzik/Resources/ThirdPartyNotices.txt'
    obj(notices, f'isa = PBXFileReference; lastKnownFileType = text; path = {q(notices)}; sourceTree = SOURCE_ROOT;')
    obj('build:' + notices, f'isa = PBXBuildFile; fileRef = {uid(notices)};')
    app_icon = 'Krabzik/AppIcon.icon'
    obj(app_icon, f'isa = PBXFileReference; lastKnownFileType = folder.iconcomposer.icon; path = {q(app_icon)}; sourceTree = SOURCE_ROOT;')
    obj('build:' + app_icon, f'isa = PBXBuildFile; fileRef = {uid(app_icon)};')
    developer_icons = 'Krabzik/Resources/DeveloperIcons'
    obj(developer_icons, f'isa = PBXFileReference; lastKnownFileType = folder; path = {q(developer_icons)}; sourceTree = SOURCE_ROOT;')
    obj('build:' + developer_icons, f'isa = PBXBuildFile; fileRef = {uid(developer_icons)};')
    for path in app_sources + test_sources:
        rel = path.relative_to(root).as_posix()
        obj(rel, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(rel)}; sourceTree = SOURCE_ROOT;')
        obj('build:' + rel, f'isa = PBXBuildFile; fileRef = {uid(rel)};')
    app_product = obj('app-product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = "Braket.app"; sourceTree = BUILT_PRODUCTS_DIR;')
    test_product = obj('test-product', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = KrabzikTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
    obj('source-group', f'isa = PBXGroup; name = Braket; children = ({uid(app_icon)}, {", ".join(uid(p.relative_to(root).as_posix()) for p in app_sources)},); sourceTree = "<group>";')
    obj('test-group', f'isa = PBXGroup; name = KrabzikTests; children = ({", ".join(uid(p.relative_to(root).as_posix()) for p in test_sources)},); sourceTree = "<group>";')
    obj('products', f'isa = PBXGroup; name = Products; children = ({app_product}, {test_product},); sourceTree = "<group>";')
    obj('main-group', f'isa = PBXGroup; children = ({uid("source-group")}, {uid("test-group")}, {uid("products")},); sourceTree = "<group>";')
    for name, files in [('app', app_sources), ('test', test_sources)]:
        obj(name + '-sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({", ".join(uid("build:" + p.relative_to(root).as_posix()) for p in files)},); runOnlyForDeploymentPostprocessing = 0;')
        framework = uid('mysql-build') + ',' + uid('sparkle-build') + ',' + uid('syntax-build') + ',' + uid('treesitter-build') + ',' if name == 'app' else ''
        obj(name + '-frameworks', f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({framework}); runOnlyForDeploymentPostprocessing = 0;')
        resources = ', '.join(uid('build:' + resource) for resource in [notices, app_icon, developer_icons]) + ',' if name == 'app' else ''
        obj(name + '-resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({resources}); runOnlyForDeploymentPostprocessing = 0;')
    obj('test-proxy', f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {uid("app-target")}; remoteInfo = Braket;')
    obj('test-dependency', f'isa = PBXTargetDependency; target = {uid("app-target")}; targetProxy = {uid("test-proxy")};')
    obj('sparkle-package', 'isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/sparkle-project/Sparkle"; requirement = { kind = exactVersion; version = 2.10.1; };')
    obj('sparkle-product', f'isa = XCSwiftPackageProductDependency; package = {uid("sparkle-package")}; productName = Sparkle;')
    obj('sparkle-build', f'isa = PBXBuildFile; productRef = {uid("sparkle-product")};')
    obj('syntax-package', 'isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/CodeEditApp/CodeEditLanguages"; requirement = { kind = revision; revision = 32a1ddcb44d0bcf9bdb41ae426fa1bb7198e62fe; };')
    obj('syntax-product', f'isa = XCSwiftPackageProductDependency; package = {uid("syntax-package")}; productName = CodeEditLanguages;')
    obj('syntax-build', f'isa = PBXBuildFile; productRef = {uid("syntax-product")};')
    obj('treesitter-package', 'isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/ChimeHQ/SwiftTreeSitter.git"; requirement = { kind = exactVersion; version = 0.9.0; };')
    obj('treesitter-product', f'isa = XCSwiftPackageProductDependency; package = {uid("treesitter-package")}; productName = SwiftTreeSitter;')
    obj('treesitter-build', f'isa = PBXBuildFile; productRef = {uid("treesitter-product")};')
    obj('mysql-package', 'isa = XCLocalSwiftPackageReference; relativePath = Vendor/MySQLNIO;')
    obj('mysql-product', f'isa = XCSwiftPackageProductDependency; package = {uid("mysql-package")}; productName = MySQLNIO;')
    obj('mysql-build', f'isa = PBXBuildFile; productRef = {uid("mysql-product")};')
    for kind, name, product in [('app', 'Braket', app_product), ('test', 'KrabzikTests', test_product)]:
        product_type = 'com.apple.product-type.application' if kind == 'app' else 'com.apple.product-type.bundle.unit-test'
        dependency = '' if kind == 'app' else uid('test-dependency') + ','
        packages = uid('mysql-product') + ',' + uid('sparkle-product') + ',' + uid('syntax-product') + ',' + uid('treesitter-product') + ',' if kind == 'app' else ''
        obj(kind + '-target', f'isa = PBXNativeTarget; buildConfigurationList = {uid(kind + "-configs")}; buildPhases = ({uid(kind + "-sources")}, {uid(kind + "-frameworks")}, {uid(kind + "-resources")},); buildRules = (); dependencies = ({dependency}); packageProductDependencies = ({packages}); name = {name}; productName = {name}; productReference = {product}; productType = "{product_type}";')

    for scope in ['project', 'app', 'test']:
        for config in ['Debug', 'Release']:
            settings = {
                'MACOSX_DEPLOYMENT_TARGET': '14.0', 'SWIFT_VERSION': '6.0',
                'CLANG_ENABLE_MODULES': 'YES', 'SDKROOT': 'macosx',
                # Debug compila solo para esta máquina; Release es universal, porque
                # ese binario es el que se instala en /Applications (ver AGENTS.md).
                'ONLY_ACTIVE_ARCH': 'YES' if config == 'Debug' else 'NO',
                'ARCHS': '$(ARCHS_STANDARD)',
                'CODE_SIGN_IDENTITY': 'Apple Development', 'CODE_SIGN_STYLE': 'Manual',
                'DEVELOPMENT_TEAM': '6P3J382F8G',
                # Un aviso del compilador rompe el build. La válvula de escape es la
                # invocación (xcodebuild SWIFT_TREAT_WARNINGS_AS_ERRORS=NO), nunca editar esto.
                'SWIFT_TREAT_WARNINGS_AS_ERRORS': 'YES',
                'GCC_TREAT_WARNINGS_AS_ERRORS': 'YES',
            }
            if scope == 'project':
                settings.update({'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if config == 'Debug' else '-O', 'DEBUG_INFORMATION_FORMAT': 'dwarf' if config == 'Debug' else 'dwarf-with-dsym', 'ENABLE_TESTABILITY': 'YES' if config == 'Debug' else 'NO', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG' if config == 'Debug' else '', 'GCC_OPTIMIZATION_LEVEL': '0' if config == 'Debug' else 's'})
            elif scope == 'app':
                settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
                settings.update({'PRODUCT_BUNDLE_IDENTIFIER': 'com.krabzik.ide', 'PRODUCT_NAME': 'Braket', 'PRODUCT_MODULE_NAME': 'Krabzik', 'INFOPLIST_FILE': 'Krabzik/Info.plist', 'GENERATE_INFOPLIST_FILE': 'NO', 'ENABLE_APP_SANDBOX': 'NO', 'ENABLE_HARDENED_RUNTIME': 'YES', 'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/../Frameworks', 'COMBINE_HIDPI_IMAGES': 'YES', 'CURRENT_PROJECT_VERSION': BUILD_NUMBER, 'MARKETING_VERSION': MARKETING_VERSION})
            else:
                settings.update({'PRODUCT_BUNDLE_IDENTIFIER': 'com.krabzik.ide.tests', 'PRODUCT_NAME': 'KrabzikTests', 'GENERATE_INFOPLIST_FILE': 'YES', 'TEST_HOST': '$(BUILT_PRODUCTS_DIR)/Braket.app/Contents/MacOS/Braket', 'BUNDLE_LOADER': '$(TEST_HOST)', 'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks'})
            obj(scope + '-' + config, 'isa = XCBuildConfiguration; name = ' + config + '; buildSettings = { ' + ' '.join(f'{k} = {q(v)};' for k, v in settings.items()) + ' };')
        obj(scope + '-configs', f'isa = XCConfigurationList; buildConfigurations = ({uid(scope + "-Debug")}, {uid(scope + "-Release")},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    obj('project', f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastSwiftUpdateCheck = 1600; LastUpgradeCheck = 1600; TargetAttributes = {{ {uid("test-target")} = {{ TestTargetID = {uid("app-target")}; }}; }}; }}; buildConfigurationList = {uid("project-configs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = es; hasScannedForEncodings = 0; knownRegions = (es, en, Base,); mainGroup = {uid("main-group")}; productRefGroup = {uid("products")}; projectDirPath = ""; projectRoot = ""; packageReferences = ({uid("mysql-package")}, {uid("sparkle-package")}, {uid("syntax-package")}, {uid("treesitter-package")},); targets = ({uid("app-target")}, {uid("test-target")},);')
    pbxproj = ('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'
               + '\n'.join(objects) + f'\n}}; rootObject = {uid("project")}; }}\n')
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('app-target')}" BuildableName="Braket.app" BlueprintName="Braket" ReferencedContainer="container:Braket.xcodeproj"/></BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('test-target')}" BuildableName="KrabzikTests.xctest" BlueprintName="KrabzikTests" ReferencedContainer="container:Braket.xcodeproj"/></TestableReference></Testables></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('app-target')}" BuildableName="Braket.app" BlueprintName="Braket" ReferencedContainer="container:Braket.xcodeproj"/></BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('app-target')}" BuildableName="Braket.app" BlueprintName="Braket" ReferencedContainer="container:Braket.xcodeproj"/></BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
    return pbxproj, scheme

def write():
    pbxproj, scheme = render()
    PBXPROJ.write_text(pbxproj)
    SCHEME.write_text(scheme)
    print('Braket.xcodeproj generated')

def check():
    """0 si el proyecto en disco coincide con las fuentes; 1 si no, diciendo qué falta."""
    pbxproj, scheme = render()
    problems = []

    # Diferencia de conjuntos sobre las rutas .swift: es la información que de
    # verdad hace falta cuando alguien se olvidó de regenerar.
    app_sources, test_sources = swift_sources()
    on_disk = {p.relative_to(root).as_posix() for p in app_sources + test_sources}
    try:
        registered = set(re.findall(r'path = "([^"]+\.swift)"', PBXPROJ.read_text()))
    except FileNotFoundError:
        problems.append('no existe Braket.xcodeproj/project.pbxproj')
        registered = set()
    for path in sorted(on_disk - registered):
        problems.append(f'fuente nueva sin registrar: {path}')
    for path in sorted(registered - on_disk):
        problems.append(f'registrada pero ya no existe: {path}')

    for target, expected in ((PBXPROJ, pbxproj), (SCHEME, scheme)):
        name = target.relative_to(root).as_posix()
        if not target.exists():
            problems.append(f'falta {name}')
        elif target.read_text() != expected:
            problems.append(f'{name} no coincide con lo que genera el script')

    if not problems:
        return 0
    print('El proyecto Xcode está desactualizado:')
    for problem in problems:
        print(f'  - {problem}')
    print('Ejecutá: python3 scripts/generate_project.py')
    return 1

if __name__ == '__main__':
    arguments = sys.argv[1:]
    if arguments == ['--check']:
        sys.exit(check())
    if arguments:
        print(f'uso: {Path(__file__).name} [--check]', file=sys.stderr)
        sys.exit(2)
    write()
