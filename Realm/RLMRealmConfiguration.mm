////////////////////////////////////////////////////////////////////////////
//
// Copyright 2015 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMRealmConfiguration_Private.hpp"
#import "RLMSchema_Private.h"
#import <realm/db.hpp>
#import <realm/group.hpp>
#import <realm/object-store/object_store.hpp>
#import <realm/session_admission.hpp>
#import <algorithm>
#import <functional>

#import "RLMObjectSchema_Private.hpp"
#import "RLMRealm_Private.h"
#import "RLMSchema_Private.hpp"
#import "RLMUtil.hpp"

#import <realm/object-store/schema.hpp>
#import <realm/object-store/shared_realm.hpp>

static NSString *const c_RLMRealmConfigurationProperties[] = {
    @"fileURL",
    @"sessionAdmission",
    @"inMemoryIdentifier",
    @"encryptionKey",
    @"readOnly",
    @"schemaVersion",
    @"migrationBlock",
    @"deleteRealmIfMigrationNeeded",
    @"shouldCompactOnLaunch",
    @"dynamic",
    @"customSchema",
};

static NSString *const c_defaultRealmFileName = @"default.realm";
RLMRealmConfiguration *s_defaultConfiguration;

NSString *RLMRealmPathForFileAndBundleIdentifier(NSString *fileName, NSString *bundleIdentifier) {
    return [RLMDefaultDirectoryForBundleIdentifier(bundleIdentifier)
            stringByAppendingPathComponent:fileName];
}

NSString *RLMRealmPathForFile(NSString *fileName) {
    static NSString *directory = RLMDefaultDirectoryForBundleIdentifier(nil);
    return [directory stringByAppendingPathComponent:fileName];
}

NSErrorDomain const RLMRealmSessionAdmissionErrorDomain = @"io.realm.session-admission";

NSError *RLMRealmSessionAdmissionErrorFromException(const realm::SessionAdmissionError& error) {
    return [NSError errorWithDomain:RLMRealmSessionAdmissionErrorDomain code:NSInteger(error.reason)
        userInfo:@{NSLocalizedDescriptionKey: @(error.what())}];
}

@interface RLMRealmFileInspection ()
- (instancetype)initWithURL:(NSURL *)url exists:(BOOL)exists version:(NSNumber *)version;
@end
@implementation RLMRealmFileInspection
- (instancetype)initWithURL:(NSURL *)url exists:(BOOL)exists version:(NSNumber *)version {
    if ((self = [super init])) { _fileURL = [url copy]; _fileExists = exists; _schemaVersion = version; }
    return self;
}
@end

@interface RLMRealmSessionAdmission ()
- (instancetype)initWithCore:(std::shared_ptr<const realm::SessionAdmission>)value;
- (std::shared_ptr<const realm::SessionAdmission>)coreAdmission;
@end
@implementation RLMRealmSessionAdmission {
    std::shared_ptr<const realm::SessionAdmission> _value;
}
- (instancetype)initWithCore:(std::shared_ptr<const realm::SessionAdmission>)value {
    if ((self = [super init])) _value = std::move(value);
    return self;
}
- (std::shared_ptr<const realm::SessionAdmission>)coreAdmission { return _value; }
- (instancetype)initWithIdentifier:(NSString *)identifier objectClasses:(NSArray<Class> *)classes error:(NSError **)error {
    try {
        auto schema = [RLMSchema schemaWithObjectClasses:classes].objectStoreCopy;
        std::vector<realm::SessionAdmission::Table> tables;
        for (const auto& object : schema) {
            realm::SessionAdmission::Table table;
            table.name = realm::ObjectStore::table_name_for_object_type(object.name);
            table.kind = unsigned(object.table_type); table.primary_key = object.primary_key;
            for (const auto& property : object.persisted_properties) {
                realm::SessionAdmission::Column column; column.name = property.name;
                using T = realm::PropertyType;
                switch (property.type & ~T::Flags) {
                    case T::Int: column.type = realm::type_Int; break;
                    case T::Bool: column.type = realm::type_Bool; break;
                    case T::String: column.type = realm::type_String; break;
                    case T::Data: column.type = realm::type_Binary; break;
                    case T::Date: column.type = realm::type_Timestamp; break;
                    case T::Float: column.type = realm::type_Float; break;
                    case T::Double: column.type = realm::type_Double; break;
                    case T::Object: column.type = realm::type_Link;
                        column.link_target = realm::ObjectStore::table_name_for_object_type(property.object_type); break;
                    case T::Mixed: column.type = realm::type_Mixed; break;
                    case T::ObjectId: column.type = realm::type_ObjectId; break;
                    case T::Decimal: column.type = realm::type_Decimal; break;
                    case T::UUID: column.type = realm::type_UUID; break;
                    default: throw realm::SessionAdmissionError(realm::SessionAdmissionError::Reason::invalid_descriptor);
                }
                column.nullable = realm::is_nullable(property.type);
                column.collection = realm::is_array(property.type) ? 1 : realm::is_set(property.type) ? 2
                    : realm::is_dictionary(property.type) ? 4 : 0;
                column.indexed = property.requires_index();
                column.fulltext_indexed = property.requires_fulltext_index();
                table.columns.push_back(std::move(column));
            }
            tables.push_back(std::move(table));
        }
        std::string admissionIdentifier;
        RLMNSStringToStdString(admissionIdentifier, identifier);
        return [self initWithCore:std::make_shared<const realm::SessionAdmission>(std::move(admissionIdentifier), std::move(tables))];
    } catch (const realm::SessionAdmissionError& ex) {
        RLMSetErrorOrThrow(RLMRealmSessionAdmissionErrorFromException(ex), error); return nil;
    } catch (const std::exception& ex) {
        RLMSetErrorOrThrow([NSError errorWithDomain:RLMRealmSessionAdmissionErrorDomain
            code:RLMRealmSessionAdmissionErrorInvalidDescriptor userInfo:@{NSLocalizedDescriptionKey: @(ex.what())}], error);
        return nil;
    }
}
- (NSString *)identifier { return @(_value->identifier().c_str()); }
- (NSData *)fingerprint { return [NSData dataWithBytes:_value->identity().data() length:_value->identity().size()]; }
- (id)copyWithZone:(NSZone *)zone { (void)zone; return self; }
- (BOOL)isEqual:(id)object {
    return [object isKindOfClass:RLMRealmSessionAdmission.class]
        && [self.fingerprint isEqual:((RLMRealmSessionAdmission *)object).fingerprint];
}
- (NSUInteger)hash { return self.fingerprint.hash; }
+ (BOOL)performExclusiveFileAccessWithConfigurations:(NSArray<RLMRealmConfiguration *> *)configurations
    body:(BOOL (^)(NSArray<RLMRealmFileInspection *> *, NSError **))body error:(NSError **)error {
    try {
        using R = realm::SessionAdmissionError::Reason;
        if (!configurations.count || configurations.count > 64) throw realm::SessionAdmissionError(R::invalid_descriptor);
        std::vector<realm::Realm::Config> values;
        for (RLMRealmConfiguration *configuration in configurations) {
            auto config = configuration.config;
            if (!config.session_admission || config.in_memory || config.path.empty() || configuration.seedFilePath)
                throw realm::SessionAdmissionError(R::unsupported_configuration);
            realm::SessionAdmission::validate_payload_path(config.path);
            values.push_back(std::move(config));
        }
        std::sort(values.begin(), values.end(), [](const auto& a, const auto& b) { return a.path < b.path; });
        for (size_t i = 1; i < values.size(); ++i) {
            if (values[i-1].path == values[i].path && (values[i-1].encryption_key != values[i].encryption_key
                || realm::SessionAdmission::identity_of(values[i-1].session_admission)
                    != realm::SessionAdmission::identity_of(values[i].session_admission)))
                throw realm::SessionAdmissionError(R::invalid_descriptor);
        }
        values.erase(std::unique(values.begin(), values.end(), [](const auto& a, const auto& b) { return a.path == b.path; }), values.end());
        for (const auto& config : values) {
            NSURL *parent = [[NSURL fileURLWithPath:@(config.path.c_str())] URLByDeletingLastPathComponent];
            NSError *directoryError = nil;
            if (![NSFileManager.defaultManager createDirectoryAtURL:parent withIntermediateDirectories:YES
                attributes:nil error:&directoryError]) { RLMSetErrorOrThrow(directoryError, error); return NO; }
        }
        __block NSError *bodyError = nil;
        bool succeeded = false;
        std::function<void(size_t)> acquire = [&](size_t index) {
            if (index < values.size()) {
                if (!realm::DB::call_with_lock(values[index].path, [&](const std::string&) { acquire(index + 1); }))
                    throw realm::SessionAdmissionError(R::busy);
                return;
            }
            NSMutableArray<RLMRealmFileInspection *> *facts = [NSMutableArray new];
            for (const auto& config : values) {
                realm::SessionAdmission::validate_payload_path(config.path);
                bool exists = realm::util::File::exists(config.path);
                NSNumber *version = nil;
                if (exists) {
                    try {
                        realm::Group physical(config.path, config.encryption_key.empty() ? nullptr : config.encryption_key.data());
                        config.session_admission->inspect(physical);
                        auto schemaVersion = realm::ObjectStore::get_schema_version(physical);
                        if (schemaVersion != realm::ObjectStore::NotVersioned) version = @(schemaVersion);
                    } catch (const realm::SessionAdmissionError&) { throw; }
                    catch (...) { throw realm::SessionAdmissionError(R::unreadable); }
                }
                [facts addObject:[[RLMRealmFileInspection alloc] initWithURL:[NSURL fileURLWithPath:@(config.path.c_str())]
                    exists:exists version:version]];
            }
            // Preserve the supplied operation paths; never canonicalize only
            // their locks while leaving an alias for a destructive callback.
            for (const auto& config : values)
                realm::SessionAdmission::validate_payload_path(config.path);
            succeeded = body(facts, &bodyError);
        };
        acquire(0);
        if (!succeeded) {
            RLMSetErrorOrThrow(bodyError ?: [NSError errorWithDomain:RLMRealmSessionAdmissionErrorDomain
                code:RLMRealmSessionAdmissionErrorUnreadable userInfo:nil], error); return NO;
        }
        return YES;
    } catch (const realm::SessionAdmissionError& ex) {
        RLMSetErrorOrThrow(RLMRealmSessionAdmissionErrorFromException(ex), error); return NO;
    } catch (const std::exception& ex) {
        RLMSetErrorOrThrow([NSError errorWithDomain:RLMRealmSessionAdmissionErrorDomain
            code:RLMRealmSessionAdmissionErrorUnreadable userInfo:@{NSLocalizedDescriptionKey: @(ex.what())}], error); return NO;
    }
}
@end

@implementation RLMRealmConfiguration {
    realm::Realm::Config _config;
}

- (RLMRealmSessionAdmission *)sessionAdmission {
    return _config.session_admission ? [[RLMRealmSessionAdmission alloc] initWithCore:_config.session_admission] : nil;
}
- (void)setSessionAdmission:(RLMRealmSessionAdmission *)admission {
    _config.session_admission = admission ? [admission coreAdmission] : nullptr;
}

- (realm::Realm::Config&)configRef {
    return _config;
}

- (std::string const&)path {
    return _config.path;
}

+ (instancetype)defaultConfiguration {
    return [[self rawDefaultConfiguration] copy];
}

+ (void)setDefaultConfiguration:(RLMRealmConfiguration *)configuration {
    if (!configuration) {
        @throw RLMException(@"Cannot set the default configuration to nil.");
    }
    @synchronized(c_defaultRealmFileName) {
        s_defaultConfiguration = [configuration copy];
    }
}

+ (RLMRealmConfiguration *)rawDefaultConfiguration {
    RLMRealmConfiguration *configuration;
    @synchronized(c_defaultRealmFileName) {
        if (!s_defaultConfiguration) {
            s_defaultConfiguration = [[RLMRealmConfiguration alloc] init];
        }
        configuration = s_defaultConfiguration;
    }
    return configuration;
}

+ (void)resetRealmConfigurationState {
    @synchronized(c_defaultRealmFileName) {
        s_defaultConfiguration = nil;
    }
}

- (instancetype)init {
    self = [super init];
    if (self) {
        static NSURL *defaultRealmURL = [NSURL fileURLWithPath:RLMRealmPathForFile(c_defaultRealmFileName)];
        self.fileURL = defaultRealmURL;
        self.schemaVersion = 0;
        self.cache = YES;
        _config.automatically_handle_backlinks_in_migrations = true;
    }

    return self;
}

- (instancetype)copyWithZone:(NSZone *)zone {
    RLMRealmConfiguration *configuration = [[[self class] allocWithZone:zone] init];
    configuration->_config = _config;
    configuration->_cache = _cache;
    configuration->_dynamic = _dynamic;
    configuration->_migrationBlock = _migrationBlock;
    configuration->_shouldCompactOnLaunch = _shouldCompactOnLaunch;
    configuration->_customSchema = _customSchema;
    configuration->_migrationObjectClass = _migrationObjectClass;
    configuration->_seedFilePath = _seedFilePath;
    return configuration;
}

- (NSString *)description {
    NSMutableString *string = [NSMutableString stringWithFormat:@"%@ {\n", self.class];
    for (NSString *key : c_RLMRealmConfigurationProperties) {
        NSString *description = [[self valueForKey:key] description];
        description = [description stringByReplacingOccurrencesOfString:@"\n" withString:@"\n\t"];

        [string appendFormat:@"\t%@ = %@;\n", key, description];
    }
    return [string stringByAppendingString:@"}"];
}

- (NSURL *)fileURL {
    if (_config.in_memory) {
        return nil;
    }
    return [NSURL fileURLWithPath:@(_config.path.c_str())];
}

- (void)setFileURL:(NSURL *)fileURL {
    NSString *path = fileURL.path;
    if (path.length == 0) {
        @throw RLMException(@"Realm path must not be empty");
    }

    RLMNSStringToStdString(_config.path, path);
    _config.in_memory = false;
}

- (NSString *)inMemoryIdentifier {
    if (!_config.in_memory) {
        return nil;
    }
    return [@(_config.path.c_str()) lastPathComponent];
}

- (void)setInMemoryIdentifier:(NSString *)inMemoryIdentifier {
    if (inMemoryIdentifier.length == 0) {
        @throw RLMException(@"In-memory identifier must not be empty");
    }
    _seedFilePath = nil;

    RLMNSStringToStdString(_config.path, [NSTemporaryDirectory() stringByAppendingPathComponent:inMemoryIdentifier]);
    _config.in_memory = true;
}

- (void)setSeedFilePath:(NSURL *)seedFilePath {
    _seedFilePath = seedFilePath;
    if (_seedFilePath) {
        _config.in_memory = false;
    }
}

- (NSData *)encryptionKey {
    return _config.encryption_key.empty() ? nil : [NSData dataWithBytes:_config.encryption_key.data() length:_config.encryption_key.size()];
}

- (void)setEncryptionKey:(NSData * __nullable)encryptionKey {
    if (NSData *key = RLMRealmValidatedEncryptionKey(encryptionKey)) {
        auto bytes = static_cast<const char *>(key.bytes);
        _config.encryption_key.assign(bytes, bytes + key.length);
    }
    else {
        _config.encryption_key.clear();
    }
}

- (BOOL)readOnly {
    return _config.immutable() || _config.read_only();
}

- (void)updateSchemaMode {
    if (self.readOnly) {
        _config.schema_mode = realm::SchemaMode::Immutable;
    }
    else {
        _config.schema_mode = realm::SchemaMode::Automatic;
    }
}

- (void)setReadOnly:(BOOL)readOnly {
    if (readOnly) {
        if (self.deleteRealmIfMigrationNeeded) {
            @throw RLMException(@"Cannot set `readOnly` when `deleteRealmIfMigrationNeeded` is set.");
        } else if (self.shouldCompactOnLaunch) {
            @throw RLMException(@"Cannot set `readOnly` when `shouldCompactOnLaunch` is set.");
        }
        _config.schema_mode =  realm::SchemaMode::Immutable;
    }
    else if (self.readOnly) {
        _config.schema_mode = realm::SchemaMode::Automatic;
        [self updateSchemaMode];
    }
}

- (uint64_t)schemaVersion {
    return _config.schema_version;
}

- (void)setSchemaVersion:(uint64_t)schemaVersion {
    if (schemaVersion == RLMNotVersioned) {
        @throw RLMException(@"Cannot set schema version to %llu (RLMNotVersioned)", RLMNotVersioned);
    }
    _config.schema_version = schemaVersion;
}

- (BOOL)deleteRealmIfMigrationNeeded {
    return _config.schema_mode == realm::SchemaMode::SoftResetFile;
}

- (void)setDeleteRealmIfMigrationNeeded:(BOOL)deleteRealmIfMigrationNeeded {
    if (deleteRealmIfMigrationNeeded) {
        if (self.readOnly) {
            @throw RLMException(@"Cannot set `deleteRealmIfMigrationNeeded` when `readOnly` is set.");
        }
        _config.schema_mode = realm::SchemaMode::SoftResetFile;
    }
    else if (self.deleteRealmIfMigrationNeeded) {
        _config.schema_mode = realm::SchemaMode::Automatic;
    }
}

- (NSArray *)objectClasses {
    return [_customSchema.objectSchema valueForKeyPath:@"objectClass"];
}

- (void)setObjectClasses:(NSArray *)objectClasses {
    _customSchema = objectClasses ? [RLMSchema schemaWithObjectClasses:objectClasses] : nil;
    [self updateSchemaMode];
}

- (NSUInteger)maximumNumberOfActiveVersions {
    if (_config.max_number_of_active_versions > std::numeric_limits<NSUInteger>::max()) {
        return std::numeric_limits<NSUInteger>::max();
    }
    return static_cast<NSUInteger>(_config.max_number_of_active_versions);
}

- (void)setMaximumNumberOfActiveVersions:(NSUInteger)maximumNumberOfActiveVersions {
    if (maximumNumberOfActiveVersions == 0) {
        _config.max_number_of_active_versions = std::numeric_limits<uint_fast64_t>::max();
    }
    else {
        _config.max_number_of_active_versions = maximumNumberOfActiveVersions;
    }
}

- (void)setDynamic:(bool)dynamic {
    _dynamic = dynamic;
    self.cache = !dynamic;
}

- (bool)disableFormatUpgrade {
    return _config.disable_format_upgrade;
}

- (void)setDisableFormatUpgrade:(bool)disableFormatUpgrade {
    _config.disable_format_upgrade = disableFormatUpgrade;
}

- (realm::SchemaMode)schemaMode {
    return _config.schema_mode;
}

- (void)setSchemaMode:(realm::SchemaMode)mode {
    _config.schema_mode = mode;
}

- (NSString *)pathOnDisk {
    return @(_config.path.c_str());
}

- (void)setShouldCompactOnLaunch:(RLMShouldCompactOnLaunchBlock)shouldCompactOnLaunch {
    if (shouldCompactOnLaunch) {
        if (_config.immutable()) {
            @throw RLMException(@"Cannot set `shouldCompactOnLaunch` when `readOnly` is set.");
        }
        _config.should_compact_on_launch_function = shouldCompactOnLaunch;
    }
    else {
        _config.should_compact_on_launch_function = nullptr;
    }
    _shouldCompactOnLaunch = shouldCompactOnLaunch;
}

- (void)setCustomSchemaWithoutCopying:(RLMSchema *)schema {
    _customSchema = schema;
}

- (bool)disableAutomaticChangeNotifications {
    return !_config.automatic_change_notifications;
}

- (void)setDisableAutomaticChangeNotifications:(bool)disableAutomaticChangeNotifications {
    _config.automatic_change_notifications = !disableAutomaticChangeNotifications;
}

- (realm::Realm::Config)config {
    return _config;
}

@end
