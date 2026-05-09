-- MySQL dump 10.13  Distrib 8.0.44, for Linux (x86_64)
--
-- Host: localhost    Database: dev_ifritah
-- ------------------------------------------------------
-- Server version	8.0.44

/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!50503 SET NAMES utf8mb4 */;
/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
/*!40103 SET TIME_ZONE='+00:00' */;
/*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;

--
-- Table structure for table `account`
--

DROP TABLE IF EXISTS `account`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `account` (
  `id` int NOT NULL AUTO_INCREMENT,
  `code` varchar(16) NOT NULL,
  `name` varchar(64) NOT NULL,
  `type` enum('asset','liability','equity','revenue','expense') NOT NULL,
  `subtype` varchar(32) DEFAULT NULL,
  `parent_id` int DEFAULT NULL,
  `is_active` tinyint(1) NOT NULL DEFAULT '1',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_account_code` (`code`),
  KEY `idx_account_type_sub` (`type`,`subtype`),
  KEY `fk_account_parent` (`parent_id`),
  CONSTRAINT `fk_account_parent` FOREIGN KEY (`parent_id`) REFERENCES `account` (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=12 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `ambrand`
--

DROP TABLE IF EXISTS `ambrand`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `ambrand` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT 'hide',
  `brandId` bigint DEFAULT NULL,
  `brandLogoID` varchar(250) CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `brandName` varchar(250) CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `lang` varchar(5) CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci DEFAULT NULL COMMENT 'hide',
  `articleCountry` varchar(50) CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE,
  UNIQUE KEY `amBrand_id_uindex` (`id`) USING BTREE,
  KEY `brandId` (`brandId`) USING BTREE,
  KEY `brandLogoID` (`brandLogoID`) USING BTREE,
  KEY `lang` (`lang`) USING BTREE,
  KEY `brandName` (`brandName`) USING BTREE,
  KEY `articleCountry` (`articleCountry`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=35086 DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Description of all aftermarket brands';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `ambrandsaddress`
--

DROP TABLE IF EXISTS `ambrandsaddress`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `ambrandsaddress` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `addressName` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `addressType` bigint DEFAULT NULL,
  `city` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `city2` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `fax` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `logoDocId` int DEFAULT NULL,
  `name` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `phone` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `street` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `wwwURL` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `zip` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `zipCountryCode` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `lang` varchar(5) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `brandId` bigint DEFAULT NULL,
  `email` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `name2` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `zipMailbox` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `zipSpecial` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `mailbox` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `street2` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  PRIMARY KEY (`id`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=38299 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Main address of the data supplier';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `article_car`
--

DROP TABLE IF EXISTS `article_car`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `article_car` (
  `vehicleModelSeriesId` bigint NOT NULL,
  `legacyArticleId` bigint NOT NULL COMMENT 'legacyArticleId',
  PRIMARY KEY (`vehicleModelSeriesId`,`legacyArticleId`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `article_car_link`
--

DROP TABLE IF EXISTS `article_car_link`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `article_car_link` (
  `linkingTargetId` bigint NOT NULL,
  `legacyArticleId` bigint NOT NULL COMMENT 'legacyArticleId',
  PRIMARY KEY (`linkingTargetId`,`legacyArticleId`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `articlecriteria`
--

DROP TABLE IF EXISTS `articlecriteria`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `articlecriteria` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT 'hide',
  `criteriaId` bigint DEFAULT NULL,
  `criteriaDescription` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `criteriaAbbrDescription` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `criteriaType` varchar(5) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `criteriaUnitDescription` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `rawValue` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `valueKeyId` bigint DEFAULT NULL,
  `isMandatory` tinyint(1) DEFAULT '0',
  `isInterval` tinyint(1) DEFAULT '0',
  `successorCriteriaId` bigint DEFAULT NULL,
  `assemblyGroupNodeId` bigint DEFAULT NULL,
  `legacyArticleId` bigint DEFAULT NULL,
  `immediateDisplay` tinyint(1) DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=27074084 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Article criteria';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `articlecrosses`
--

DROP TABLE IF EXISTS `articlecrosses`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `articlecrosses` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `oemNumber` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `mfrId` bigint DEFAULT NULL,
  `brandName` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `assemblyGroupNodeId` bigint DEFAULT NULL,
  `legacyArticleId` bigint DEFAULT NULL,
  `number` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE,
  KEY `artcleId` (`legacyArticleId`)
) ENGINE=InnoDB AUTO_INCREMENT=30370792 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Cross-references';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `articledocs`
--

DROP TABLE IF EXISTS `articledocs`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `articledocs` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `docFileName` varchar(50) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `docFileTypeName` varchar(50) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `docId` bigint DEFAULT NULL,
  `docText` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `docTypeId` bigint DEFAULT NULL,
  `docUrl` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `assemblyGroupNodeId` bigint DEFAULT NULL,
  `legacyArticleId` bigint DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=8203512 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Articles documents';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `articleean`
--

DROP TABLE IF EXISTS `articleean`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `articleean` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `legacyArticleId` bigint DEFAULT NULL,
  `eancode` varchar(25) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=4187238 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Spare parts EAN codes';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `articlelinks`
--

DROP TABLE IF EXISTS `articlelinks`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `articlelinks` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT 'hide',
  `url` mediumtext CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `legacyArticleId` bigint DEFAULT NULL,
  `lang` varchar(5) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `description` mediumtext CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  PRIMARY KEY (`id`) USING BTREE,
  KEY `legacyArticleId` (`legacyArticleId`) USING BTREE,
  KEY `lang` (`lang`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=317385 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Useful links to web resources';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `articlemain`
--

DROP TABLE IF EXISTS `articlemain`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `articlemain` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `mainArticleId` bigint DEFAULT NULL,
  `legacyArticleId` bigint DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=2387976 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Main articles';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `articlepdfs`
--

DROP TABLE IF EXISTS `articlepdfs`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `articlepdfs` (
  `id` int NOT NULL AUTO_INCREMENT COMMENT 'hide',
  `url` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `fileName` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `typeDescription` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `headerDescription` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `assemblyGroupNodeId` int DEFAULT NULL COMMENT 'hide',
  `legacyArticleId` int DEFAULT NULL,
  `typeKeyId` int DEFAULT NULL COMMENT 'hide',
  `headerKeyId` int DEFAULT NULL COMMENT 'hide',
  `lang` varchar(5) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE,
  UNIQUE KEY `articlePdfs_id_uindex` (`id`) USING BTREE,
  UNIQUE KEY `articlePdfs_la_u_uindex` (`legacyArticleId`,`url`) USING BTREE,
  KEY `articlePdfs_legacyArticleId_index` (`legacyArticleId`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=508354 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='PDF and other media';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `articles`
--

DROP TABLE IF EXISTS `articles`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `articles` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT 'hide',
  `dataSupplierId` bigint DEFAULT NULL,
  `articleNumber` varchar(150) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  `mfrId` bigint NOT NULL,
  `additionalDescription` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `articleStatusId` bigint DEFAULT NULL COMMENT 'hide',
  `articleStatusDescription` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `articleStatusValidFromDate` bigint DEFAULT NULL,
  `quantityPerPackage` bigint DEFAULT NULL,
  `quantityPerPartPerPackage` bigint DEFAULT NULL,
  `isSelfServicePacking` tinyint(1) DEFAULT NULL,
  `hasMandatoryMaterialCertification` tinyint(1) DEFAULT NULL,
  `isRemanufacturedPart` tinyint(1) DEFAULT NULL,
  `isAccessory` tinyint(1) DEFAULT NULL,
  `genericArticleDescription` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `legacyArticleId` bigint unsigned DEFAULT NULL,
  `assemblyGroupNodeId` bigint unsigned DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE,
  KEY `articleId_index` (`legacyArticleId`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=6893356 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Articles';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `articlesvehicletrees`
--

DROP TABLE IF EXISTS `articlesvehicletrees`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `articlesvehicletrees` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `legacyArticleId` bigint DEFAULT NULL COMMENT 'legacyArticleId',
  `assemblyGroupNodeId` bigint DEFAULT NULL,
  `linkingTargetId` bigint DEFAULT NULL,
  `linkingTargetType` varchar(5) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE,
  UNIQUE KEY `legacyArticleId` (`legacyArticleId`,`assemblyGroupNodeId`,`linkingTargetId`,`linkingTargetType`) USING BTREE,
  KEY `legacyArticleId_3` (`legacyArticleId`) USING BTREE,
  KEY `assemblyGroupNodeId` (`assemblyGroupNodeId`,`linkingTargetId`,`linkingTargetType`) USING BTREE,
  KEY `linkingTargetId` (`linkingTargetId`,`linkingTargetType`) USING BTREE,
  KEY `linkingTargetId_2` (`linkingTargetId`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=651871453 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci ROW_FORMAT=DYNAMIC COMMENT='Links between vehicles and spare parts';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `articletext`
--

DROP TABLE IF EXISTS `articletext`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `articletext` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `infoId` bigint DEFAULT NULL,
  `informationTypeKey` bigint DEFAULT NULL,
  `informationTypeDescription` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `text` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `assemblyGroupNodeId` bigint DEFAULT NULL,
  `legacyArticleId` bigint DEFAULT NULL,
  `isImmediateDisplay` tinyint(1) DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=1607531 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Text information about spare parts';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `assemblygroupnodenames`
--

DROP TABLE IF EXISTS `assemblygroupnodenames`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `assemblygroupnodenames` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT 'hide',
  `assemblyGroupName` varchar(150) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `assemblyGroupNodeId` bigint DEFAULT NULL,
  `hasChilds` tinyint(1) DEFAULT NULL,
  `shortCutId` bigint DEFAULT NULL,
  `lang` varchar(5) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `parentNodeId` bigint DEFAULT '0',
  PRIMARY KEY (`id`) USING BTREE,
  UNIQUE KEY `assemblyGroupName` (`assemblyGroupName`,`assemblyGroupNodeId`,`hasChilds`,`shortCutId`,`lang`,`parentNodeId`) USING BTREE,
  KEY `lang` (`lang`) USING BTREE,
  KEY `assemblyGroupNodesId_index` (`assemblyGroupNodeId`,`lang`) USING BTREE,
  KEY `lang_2` (`lang`) USING BTREE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Assembly groups names';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `assemblygroupnodes`
--

DROP TABLE IF EXISTS `assemblygroupnodes`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `assemblygroupnodes` (
  `id` int NOT NULL AUTO_INCREMENT,
  `assemblyGroupNodeId` bigint DEFAULT NULL,
  `hasChilds` tinyint(1) DEFAULT NULL,
  `shortCutId` bigint DEFAULT NULL,
  `parentNodeId` bigint DEFAULT '0',
  `linkingTargetId` bigint DEFAULT NULL,
  `linkingTargetType` varchar(5) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE,
  UNIQUE KEY `assemblyGroupNodeId` (`assemblyGroupNodeId`,`hasChilds`,`shortCutId`,`parentNodeId`,`linkingTargetId`,`linkingTargetType`) USING BTREE,
  KEY `linkingTargetId` (`linkingTargetId`,`linkingTargetType`) USING BTREE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci ROW_FORMAT=DYNAMIC COMMENT='Assembly groups';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `axlebodytype`
--

DROP TABLE IF EXISTS `axlebodytype`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `axlebodytype` (
  `bodyTypeName` varchar(150) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT '',
  `axleId` bigint DEFAULT NULL,
  `id` int NOT NULL AUTO_INCREMENT COMMENT 'hide',
  PRIMARY KEY (`id`) USING BTREE,
  KEY `bodyTypeName` (`bodyTypeName`) USING BTREE,
  KEY `axleId` (`axleId`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=39406 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `axlebrakesizes`
--

DROP TABLE IF EXISTS `axlebrakesizes`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `axlebrakesizes` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT 'hide',
  `brakeSize` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT '',
  `brakeSizeId` bigint DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE,
  UNIQUE KEY `axleBrakeSizes_id_uindex` (`id`) USING BTREE,
  KEY `brakeSizeId` (`brakeSizeId`) USING BTREE,
  KEY `brakeSize` (`brakeSize`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=71 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `axledetails`
--

DROP TABLE IF EXISTS `axledetails`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `axledetails` (
  `id` int NOT NULL AUTO_INCREMENT,
  `axleBodyType` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `axleBodyTypeId` bigint DEFAULT NULL,
  `axleDescription` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `axleId` bigint DEFAULT NULL,
  `axleLoadFrom` bigint DEFAULT NULL,
  `axleLoadTo` bigint DEFAULT NULL,
  `axleManufacturer` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `axleModel` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `axleStyle` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `axleStyleId` bigint DEFAULT NULL,
  `axleType` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `axleTypeId` bigint DEFAULT NULL,
  `brakeType` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `brakeTypeId` bigint DEFAULT NULL,
  `wheelMount` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `wheelMountId` bigint DEFAULT NULL,
  `yearOfConstrFrom` bigint DEFAULT NULL,
  `yearOfConstrTo` bigint DEFAULT NULL,
  `driveHeightFrom` bigint DEFAULT NULL,
  `driveHeightTo` bigint DEFAULT NULL,
  `trackGauge` bigint DEFAULT NULL,
  `lang` varchar(5) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=7012 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Axle details';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `axles`
--

DROP TABLE IF EXISTS `axles`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `axles` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT 'hide',
  `axleId` bigint DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=7012 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Axles';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `bill`
--

DROP TABLE IF EXISTS `bill`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `bill` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `effective_date` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `payment_due_date` datetime DEFAULT NULL,
  `state` int NOT NULL DEFAULT '0',
  `discount` decimal(30,10) NOT NULL,
  `store_id` int NOT NULL,
  `sequence_number` bigint unsigned DEFAULT NULL,
  `merchant_id` int NOT NULL,
  `maintenance_cost` decimal(30,10) NOT NULL,
  `note` text,
  `userName` varchar(45) DEFAULT NULL,
  `client_id` int DEFAULT NULL,
  `user_phone_number` varchar(10) DEFAULT NULL,
  `qr_code` varchar(1000) DEFAULT NULL,
  `invoice_uuid` char(36) DEFAULT NULL,
  `invoice_hash` varchar(128) DEFAULT NULL,
  `branch_id` int unsigned DEFAULT NULL,
  `payment_method` int NOT NULL DEFAULT '10' COMMENT 'ZATCA payment method: 10=Cash, 30=Credit, 42=Bank, 48=Card',
  `deliver_date` date DEFAULT NULL COMMENT 'Expected delivery date',
  `invoice_xml_path` varchar(500) DEFAULT NULL COMMENT 'Filesystem path of signed XML (relative to xml-dir)',
  `total_before_vat` decimal(12,2) NOT NULL DEFAULT '0.00',
  `total_vat` decimal(12,2) NOT NULL DEFAULT '0.00',
  `total` decimal(12,2) NOT NULL DEFAULT '0.00',
  `discount_amount` decimal(12,2) NOT NULL DEFAULT '0.00',
  `amount_paid` decimal(14,2) NOT NULL DEFAULT '0.00',
  `sequence_number_str` varchar(32) GENERATED ALWAYS AS (cast(`sequence_number` as char)) VIRTUAL,
  PRIMARY KEY (`id`),
  KEY `fk_bill_branch` (`branch_id`),
  KEY `idx_bill_merchant_date` (`merchant_id`,`effective_date`),
  KEY `idx_bill_merchant_state` (`merchant_id`,`state`),
  KEY `idx_bill_payment_method` (`payment_method`),
  KEY `idx_bill_deliver_date` (`deliver_date`),
  FULLTEXT KEY `note` (`note`,`userName`,`user_phone_number`),
  CONSTRAINT `fk_bill_branch` FOREIGN KEY (`branch_id`) REFERENCES `branches` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB AUTO_INCREMENT=518 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `bill_payment`
--

DROP TABLE IF EXISTS `bill_payment`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `bill_payment` (
  `id` int NOT NULL AUTO_INCREMENT,
  `bill_id` bigint unsigned NOT NULL,
  `date` datetime NOT NULL,
  `paid_at` datetime NOT NULL,
  `amount` decimal(12,2) NOT NULL,
  `currency_id` int NOT NULL,
  `payment_method` int NOT NULL,
  `recorded_by` int DEFAULT NULL,
  `note` varchar(255) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `fk_bill_payment_user` (`recorded_by`),
  KEY `idx_bill_payment_bill` (`bill_id`),
  KEY `idx_bill_payment_paid_at` (`paid_at`),
  CONSTRAINT `fk_bill_payment_bill` FOREIGN KEY (`bill_id`) REFERENCES `bill` (`id`) ON DELETE CASCADE,
  CONSTRAINT `fk_bill_payment_user` FOREIGN KEY (`recorded_by`) REFERENCES `user` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = utf8mb4 */ ;
/*!50003 SET character_set_results = utf8mb4 */ ;
/*!50003 SET collation_connection  = utf8mb4_0900_ai_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION' */ ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = utf8mb4 */ ;
/*!50003 SET character_set_results = utf8mb4 */ ;
/*!50003 SET collation_connection  = utf8mb4_0900_ai_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION' */ ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = utf8mb4 */ ;
/*!50003 SET character_set_results = utf8mb4 */ ;
/*!50003 SET collation_connection  = utf8mb4_0900_ai_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION' */ ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;

--
-- Table structure for table `bill_product`
--

DROP TABLE IF EXISTS `bill_product`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `bill_product` (
  `id` int NOT NULL AUTO_INCREMENT,
  `product_id` bigint unsigned DEFAULT NULL,
  `bill_id` bigint unsigned NOT NULL,
  `vat` decimal(5,2) DEFAULT '15.00',
  `price` decimal(12,2) NOT NULL,
  `quantity` decimal(10,3) NOT NULL,
  `name` varchar(255) DEFAULT NULL,
  `part_name` varchar(255) DEFAULT NULL,
  `type` tinyint GENERATED ALWAYS AS ((case when (`product_id` is not null) then 0 when (`name` = _utf8mb4'maintenance_cost') then 2 else 1 end)) STORED NOT NULL,
  `discount` decimal(12,2) NOT NULL DEFAULT '0.00',
  `total_before_discount` decimal(12,2) GENERATED ALWAYS AS (round((`price` * `quantity`),2)) STORED,
  `total_before_vat` decimal(12,2) GENERATED ALWAYS AS (round((`total_before_discount` - `discount`),2)) STORED,
  `vat_total` decimal(12,2) GENERATED ALWAYS AS (round(((`total_before_vat` * `vat`) / 100),2)) STORED,
  `total_including_vat` decimal(12,2) GENERATED ALWAYS AS (round((`total_before_vat` + `vat_total`),2)) STORED,
  PRIMARY KEY (`id`),
  KEY `fk_bill_product` (`bill_id`),
  KEY `fk_product_id` (`product_id`),
  CONSTRAINT `fk_bill_product` FOREIGN KEY (`bill_id`) REFERENCES `bill` (`id`),
  CONSTRAINT `fk_product_id` FOREIGN KEY (`product_id`) REFERENCES `product` (`id`),
  CONSTRAINT `chk_price` CHECK ((`price` > 0)),
  CONSTRAINT `chk_quantity` CHECK ((`quantity` > 0))
) ENGINE=InnoDB AUTO_INCREMENT=862 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = utf8mb4 */ ;
/*!50003 SET character_set_results = utf8mb4 */ ;
/*!50003 SET collation_connection  = utf8mb4_0900_ai_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION' */ ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = utf8mb4 */ ;
/*!50003 SET character_set_results = utf8mb4 */ ;
/*!50003 SET collation_connection  = utf8mb4_0900_ai_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION' */ ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;

--
-- Table structure for table `bodymark`
--

DROP TABLE IF EXISTS `bodymark`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `bodymark` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT 'hide',
  `linkedCars` bigint DEFAULT NULL COMMENT 'hide',
  `manuName` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `markId` bigint DEFAULT NULL,
  `markName` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE,
  UNIQUE KEY `bodyMark_id_uindex` (`id`) USING BTREE,
  KEY `fk_bodyMark_bodyMarkCarIds_1` (`markId`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=50507 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `bodymarkcarids`
--

DROP TABLE IF EXISTS `bodymarkcarids`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `bodymarkcarids` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT 'hide',
  `carId` bigint DEFAULT NULL,
  `term` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `markId` bigint DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE,
  UNIQUE KEY `bodyMarkCarIds_id_uindex` (`id`) USING BTREE,
  KEY `fk_bodyMarkCarIds_cars_1` (`carId`) USING BTREE,
  KEY `fk_bodyMarkCarIds_bodyMark_1` (`markId`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=46397 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `branch_zatca_config`
--

DROP TABLE IF EXISTS `branch_zatca_config`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `branch_zatca_config` (
  `branch_id` int unsigned NOT NULL,
  `csr_org_identifier` varchar(50) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `csr_org_unit` varchar(100) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `csr_org_name` varchar(255) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `csr_country` varchar(2) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'SA',
  `csr_location` varchar(100) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `business_category` varchar(100) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'Supply activities',
  `seller_vat` varchar(15) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `seller_crn` varchar(20) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `street` varchar(255) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `building` varchar(100) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `district` varchar(255) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `postal_code` varchar(20) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `zatca_csr` text COLLATE utf8mb4_unicode_ci,
  `zatca_private_key` text COLLATE utf8mb4_unicode_ci,
  `zatca_compliance_certificate` text COLLATE utf8mb4_unicode_ci,
  `zatca_compliance_secret` text COLLATE utf8mb4_unicode_ci,
  `zatca_compliance_request_id` varchar(255) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `zatca_production_username` text COLLATE utf8mb4_unicode_ci,
  `zatca_production_password` text COLLATE utf8mb4_unicode_ci,
  `zatca_production_request_id` varchar(255) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `zatca_registered_at` datetime DEFAULT NULL,
  `zatca_status` tinyint NOT NULL DEFAULT '3' COMMENT '0=deleted, 1=active, 2=expired, 3=not active',
  `zatca_onboarded_at` datetime DEFAULT NULL,
  `csr_tin` varchar(9) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '9-digit EGS serial used in CSR CommonName',
  `csr_computer_number` varchar(64) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT 'EGS UUID used in CSR SerialNumber (3-{uuid})',
  `csr_invoice_type` varchar(10) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '1100' COMMENT '1100=both, 1000=B2B only, 0100=B2C only',
  `onboard_state` varchar(32) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'not_started' COMMENT 'not_started|csr|compliance|invoices|done|failed',
  `last_error` text COLLATE utf8mb4_unicode_ci,
  `last_attempt_at` datetime DEFAULT NULL,
  `previous_invoice_hash` varchar(255) COLLATE utf8mb4_unicode_ci DEFAULT NULL COMMENT 'base64(sha256(prev_signed_xml)); null = first document',
  `last_icv` bigint unsigned NOT NULL DEFAULT '0' COMMENT 'Strictly increasing per-EGS Invoice Counter Value (shared across bill/credit/debit)',
  PRIMARY KEY (`branch_id`),
  CONSTRAINT `fk_bzc_branch` FOREIGN KEY (`branch_id`) REFERENCES `branches` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `branches`
--

DROP TABLE IF EXISTS `branches`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `branches` (
  `id` int unsigned NOT NULL AUTO_INCREMENT,
  `name` varchar(255) COLLATE utf8mb4_unicode_ci NOT NULL,
  `address` varchar(500) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `city` varchar(100) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `phone` varchar(20) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `company_id` int NOT NULL DEFAULT '1',
  `manager_id` int unsigned DEFAULT NULL,
  `is_active` tinyint(1) NOT NULL DEFAULT '1',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_branches_name` (`name`),
  UNIQUE KEY `uq_branches_company_name` (`company_id`,`name`),
  KEY `idx_branches_active` (`is_active`),
  CONSTRAINT `fk_branches_company` FOREIGN KEY (`company_id`) REFERENCES `company` (`id`) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB AUTO_INCREMENT=28 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `car_link`
--

DROP TABLE IF EXISTS `car_link`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `car_link` (
  `linkageTargetId` bigint NOT NULL,
  `vehicleModelSeriesId` bigint NOT NULL,
  PRIMARY KEY (`linkageTargetId`,`vehicleModelSeriesId`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `cars`
--

DROP TABLE IF EXISTS `cars`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `cars` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT 'hide',
  `carId` bigint DEFAULT NULL,
  `carName` varchar(100) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `carType` varchar(5) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `firstCountry` varchar(5) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `manuId` bigint DEFAULT NULL,
  `modId` bigint DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE,
  KEY `fk_cars_manufacturers_1` (`manuId`) USING BTREE,
  KEY `fk_cars_modelSeries_1` (`modId`) USING BTREE,
  KEY `fk_cars_countries_1` (`firstCountry`) USING BTREE,
  KEY `carId` (`carId`) USING BTREE,
  KEY `carType` (`carType`) USING BTREE,
  KEY `carId_2` (`carId`,`carName`,`carType`,`firstCountry`,`manuId`,`modId`) USING BTREE,
  KEY `cars_manuId_index` (`manuId`) USING BTREE,
  KEY `cars_modId_index` (`modId`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=250299 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Vehicle types';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `cars_old`
--

DROP TABLE IF EXISTS `cars_old`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `cars_old` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT 'hide',
  `carId` bigint DEFAULT NULL,
  `carName` varchar(100) CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `carType` varchar(5) CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `firstCountry` varchar(5) CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `manuId` bigint DEFAULT NULL,
  `modId` bigint DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE,
  KEY `fk_cars_manufacturers_1` (`manuId`) USING BTREE,
  KEY `fk_cars_modelSeries_1` (`modId`) USING BTREE,
  KEY `fk_cars_countries_1` (`firstCountry`) USING BTREE,
  KEY `carId` (`carId`) USING BTREE,
  KEY `carType` (`carType`) USING BTREE,
  KEY `carId_2` (`carId`,`carName`,`carType`,`firstCountry`,`manuId`,`modId`) USING BTREE,
  KEY `cars_manuId_index` (`manuId`) USING BTREE,
  KEY `cars_modId_index` (`modId`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=223980 DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Vehicle types OLD';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `carsbodies`
--

DROP TABLE IF EXISTS `carsbodies`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `carsbodies` (
  `manuId` bigint DEFAULT NULL,
  `modelId` bigint DEFAULT NULL,
  `carId` bigint DEFAULT NULL,
  `BodyId` bigint DEFAULT '0',
  `id` int NOT NULL AUTO_INCREMENT COMMENT 'hide',
  `carType` varchar(1) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE,
  KEY `BodyId` (`BodyId`) USING BTREE,
  KEY `manuId` (`manuId`,`BodyId`) USING BTREE,
  KEY `manuId_2` (`manuId`,`modelId`,`BodyId`) USING BTREE,
  KEY `manuId_3` (`manuId`,`modelId`,`carId`) USING BTREE,
  KEY `carId` (`carId`) USING BTREE,
  KEY `modelId` (`modelId`,`carType`) USING BTREE,
  KEY `carType` (`carType`) USING BTREE,
  KEY `manuId_4` (`manuId`,`BodyId`,`carType`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=91787 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `cash_voucher`
--

DROP TABLE IF EXISTS `cash_voucher`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `cash_voucher` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `voucher_number` int NOT NULL COMMENT 'Sequential number per merchant, auto-generated',
  `voucher_type` enum('disbursement','receipt','cash_box') NOT NULL COMMENT 'disbursement=سند صرف, receipt=سند قبض, cash_box=سند صرف صندوق',
  `effective_date` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `amount` decimal(12,2) NOT NULL,
  `payment_method` enum('cash','bank_transfer') NOT NULL DEFAULT 'cash',
  `state` int NOT NULL DEFAULT '0' COMMENT '0=draft, 1=approved, 2=posted',
  `reference_type` varchar(30) DEFAULT NULL COMMENT 'purchase_bill, bill, expense, refund, other',
  `reference_id` int DEFAULT NULL COMMENT 'ID of the related entity (bill.id, purchase_bill.id, etc.)',
  `recipient_type` enum('supplier','client','employee','other') NOT NULL DEFAULT 'other',
  `recipient_id` int DEFAULT NULL COMMENT 'FK depends on recipient_type: supplier.id, client.id, user.id, or NULL',
  `recipient_name` varchar(255) NOT NULL COMMENT 'Denormalized name for display and search',
  `description` text COMMENT 'Purpose/reason for the payment or receipt',
  `note` text COMMENT 'Additional internal notes',
  `bank_name` varchar(255) DEFAULT NULL,
  `bank_account` varchar(50) DEFAULT NULL,
  `transaction_reference` varchar(100) DEFAULT NULL COMMENT 'Bank transaction/transfer number',
  `store_id` int NOT NULL,
  `merchant_id` int NOT NULL,
  `branch_id` int unsigned DEFAULT NULL,
  `created_by` int NOT NULL COMMENT 'FK to user.id — who created the voucher',
  `approved_by` int DEFAULT NULL COMMENT 'FK to user.id — who approved (NULL if draft)',
  `approved_at` datetime DEFAULT NULL COMMENT 'Timestamp of approval',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_cv_type` (`voucher_type`),
  KEY `idx_cv_state` (`state`),
  KEY `idx_cv_date` (`effective_date`),
  KEY `idx_cv_merchant_date` (`merchant_id`,`effective_date`),
  KEY `idx_cv_merchant_type` (`merchant_id`,`voucher_type`),
  KEY `idx_cv_recipient` (`recipient_type`,`recipient_id`),
  KEY `idx_cv_reference` (`reference_type`,`reference_id`),
  KEY `fk_cv_store` (`store_id`),
  KEY `fk_cv_branch` (`branch_id`),
  KEY `fk_cv_created_by` (`created_by`),
  KEY `fk_cv_approved_by` (`approved_by`),
  CONSTRAINT `fk_cv_approved_by` FOREIGN KEY (`approved_by`) REFERENCES `user` (`id`) ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT `fk_cv_branch` FOREIGN KEY (`branch_id`) REFERENCES `branches` (`id`) ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT `fk_cv_created_by` FOREIGN KEY (`created_by`) REFERENCES `user` (`id`) ON UPDATE CASCADE,
  CONSTRAINT `fk_cv_store` FOREIGN KEY (`store_id`) REFERENCES `store` (`id`) ON UPDATE CASCADE,
  CONSTRAINT `chk_cv_amount` CHECK ((`amount` > 0)),
  CONSTRAINT `chk_cv_bank_fields` CHECK (((`payment_method` <> _utf8mb4'bank_transfer') or ((`bank_name` is not null) and (`bank_account` is not null)))),
  CONSTRAINT `chk_cv_state` CHECK ((`state` in (0,1,2)))
) ENGINE=InnoDB AUTO_INCREMENT=58 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Temporary view structure for view `cash_voucher_summary`
--

DROP TABLE IF EXISTS `cash_voucher_summary`;
/*!50001 DROP VIEW IF EXISTS `cash_voucher_summary`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `cash_voucher_summary` AS SELECT
 1 AS `voucher_type`,
 1 AS `state`,
 1 AS `merchant_id`,
 1 AS `voucher_count`,
 1 AS `total_amount`,
 1 AS `month`*/;
SET character_set_client = @saved_cs_client;

--
-- Table structure for table `client`
--

DROP TABLE IF EXISTS `client`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `client` (
  `id` int unsigned NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL,
  `number` varchar(50) DEFAULT NULL,
  `company_name` varchar(255) DEFAULT NULL,
  `email` varchar(255) DEFAULT NULL,
  `phone` varchar(20) DEFAULT NULL,
  `address` varchar(500) DEFAULT NULL,
  `short_address` varchar(200) DEFAULT NULL,
  `street` varchar(255) DEFAULT NULL,
  `building` varchar(50) DEFAULT NULL,
  `district` varchar(255) DEFAULT NULL,
  `city` varchar(255) DEFAULT NULL,
  `postal_code` varchar(10) DEFAULT NULL,
  `country` varchar(2) NOT NULL DEFAULT 'SA',
  `scheme_id` varchar(10) DEFAULT 'CRN',
  `registration_id` varchar(50) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `vat_number` varchar(15) NOT NULL,
  `commercial_registration` varchar(10) DEFAULT NULL,
  `is_deleted` tinyint(1) NOT NULL DEFAULT '0',
  `bank_account` varchar(50) DEFAULT NULL,
  `preferred_payment_method` tinyint NOT NULL DEFAULT '10' COMMENT '10=cash, 20=bank, 30=credit',
  `credit_limit` decimal(12,2) NOT NULL DEFAULT '0.00',
  `payment_terms_days` int NOT NULL DEFAULT '0',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_vat_number` (`vat_number`),
  UNIQUE KEY `uq_email` (`email`),
  KEY `idx_supplier_payment_method` (`preferred_payment_method`)
) ENGINE=InnoDB AUTO_INCREMENT=120 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `company`
--

DROP TABLE IF EXISTS `company`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `company` (
  `id` int NOT NULL AUTO_INCREMENT,
  `state` int NOT NULL DEFAULT '0',
  `name` varchar(45) NOT NULL,
  `vat_number` varchar(255) NOT NULL,
  `vat_registration_number` varchar(15) DEFAULT NULL,
  `commercial_registration_number` varchar(10) DEFAULT NULL,
  `name_ar` varchar(255) DEFAULT NULL,
  `business_category` varchar(255) DEFAULT 'Supply activities',
  PRIMARY KEY (`id`),
  CONSTRAINT `chk_vat_registration_number` CHECK (regexp_like(`vat_registration_number`,_utf8mb4'^3[0-9]{13}3$'))
) ENGINE=InnoDB AUTO_INCREMENT=3 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `countries`
--

DROP TABLE IF EXISTS `countries`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `countries` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT 'hide',
  `countryCode` varchar(5) CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `countryName` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci,
  `usage` bigint DEFAULT NULL COMMENT 'hide',
  `lang` varchar(5) CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE,
  UNIQUE KEY `countries_id_uindex` (`id`) USING BTREE,
  KEY `countryCode` (`countryCode`) USING BTREE,
  KEY `lang` (`lang`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=9946 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Countries';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `countrygroups`
--

DROP TABLE IF EXISTS `countrygroups`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `countrygroups` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT 'hide',
  `countryName` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `tecdocCode` varchar(50) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `lang` varchar(5) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE,
  UNIQUE KEY `countryGroups_id_uindex` (`id`) USING BTREE,
  KEY `fk_countryGroups_countries_1` (`tecdocCode`) USING BTREE,
  KEY `fk_countryGroups_countries_2` (`lang`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=937 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Country groups';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `credit_note`
--

DROP TABLE IF EXISTS `credit_note`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `credit_note` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `bill_id` bigint unsigned NOT NULL,
  `state` int DEFAULT NULL,
  `NOTE` text,
  `created_at` datetime DEFAULT CURRENT_TIMESTAMP,
  `invoice_uuid` char(36) DEFAULT NULL,
  `invoice_hash` varchar(128) DEFAULT NULL,
  `invoice_qr` mediumtext,
  `invoice_xml_path` varchar(500) DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `unique_bill_id` (`bill_id`),
  KEY `idx_cn_bill_id` (`bill_id`),
  CONSTRAINT `fk_credit_note` FOREIGN KEY (`bill_id`) REFERENCES `bill` (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=118 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `criteria`
--

DROP TABLE IF EXISTS `criteria`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `criteria` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `criteriaId` bigint DEFAULT NULL,
  `criteriaName` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `criteriaShortName` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `criteriaType` varchar(5) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `isInterval` tinyint(1) DEFAULT NULL,
  `lang` varchar(5) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `criteriaUnit` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `successorId` bigint DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='List of all criterias';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `dashboard_daily_rollup`
--

DROP TABLE IF EXISTS `dashboard_daily_rollup`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `dashboard_daily_rollup` (
  `merchant_id` int NOT NULL,
  `store_id` int NOT NULL,
  `bucket_date` date NOT NULL,
  `invoice_count` int NOT NULL DEFAULT '0',
  `revenue` decimal(14,2) NOT NULL DEFAULT '0.00',
  `revenue_before_vat` decimal(14,2) NOT NULL DEFAULT '0.00',
  `output_vat` decimal(14,2) NOT NULL DEFAULT '0.00',
  `discount` decimal(14,2) NOT NULL DEFAULT '0.00',
  `purchase_count` int NOT NULL DEFAULT '0',
  `purchases_total` decimal(14,2) NOT NULL DEFAULT '0.00',
  `purchases_before_vat` decimal(14,2) NOT NULL DEFAULT '0.00',
  `input_vat` decimal(14,2) NOT NULL DEFAULT '0.00',
  `credit_note_count` int NOT NULL DEFAULT '0',
  `credit_note_total` decimal(14,2) NOT NULL DEFAULT '0.00',
  PRIMARY KEY (`merchant_id`,`store_id`,`bucket_date`),
  KEY `idx_rollup_merchant_date` (`merchant_id`,`bucket_date`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `debit_note`
--

DROP TABLE IF EXISTS `debit_note`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `debit_note` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `bill_id` bigint unsigned NOT NULL,
  `state` int DEFAULT NULL COMMENT '1=pending, 3=submitted',
  `note` text COMMENT 'KSA-10 reason',
  `created_at` datetime DEFAULT CURRENT_TIMESTAMP,
  `invoice_uuid` char(36) DEFAULT NULL,
  `invoice_hash` varchar(128) DEFAULT NULL,
  `invoice_qr` mediumtext,
  `invoice_xml_path` varchar(500) DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_dn_bill_id` (`bill_id`),
  KEY `idx_dn_state` (`state`),
  CONSTRAINT `fk_debit_note_bill` FOREIGN KEY (`bill_id`) REFERENCES `bill` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `expense`
--

DROP TABLE IF EXISTS `expense`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `expense` (
  `id` int NOT NULL AUTO_INCREMENT,
  `merchant_id` int NOT NULL,
  `store_id` int NOT NULL,
  `category_id` int NOT NULL,
  `amount` decimal(12,2) NOT NULL,
  `vat_amount` decimal(12,2) NOT NULL DEFAULT '0.00',
  `spent_at` date NOT NULL,
  `note` varchar(255) DEFAULT NULL,
  `created_by` int NOT NULL,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_expense_merchant_date` (`merchant_id`,`spent_at`),
  KEY `idx_expense_store_date` (`store_id`,`spent_at`),
  KEY `idx_expense_cat` (`category_id`),
  KEY `fk_expense_user` (`created_by`),
  CONSTRAINT `fk_expense_cat` FOREIGN KEY (`category_id`) REFERENCES `expense_category` (`id`),
  CONSTRAINT `fk_expense_store` FOREIGN KEY (`store_id`) REFERENCES `store` (`id`),
  CONSTRAINT `fk_expense_user` FOREIGN KEY (`created_by`) REFERENCES `user` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `expense_category`
--

DROP TABLE IF EXISTS `expense_category`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `expense_category` (
  `id` int NOT NULL AUTO_INCREMENT,
  `code` varchar(32) NOT NULL,
  `name` varchar(64) NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_expense_cat_code` (`code`)
) ENGINE=InnoDB AUTO_INCREMENT=6 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `genericarticles`
--

DROP TABLE IF EXISTS `genericarticles`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `genericarticles` (
  `articleId` bigint DEFAULT NULL,
  `genericArticleId` bigint DEFAULT NULL,
  KEY `artcleIdIndex` (`articleId`) USING BTREE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Generic articles';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `genericarticlesgroups`
--

DROP TABLE IF EXISTS `genericarticlesgroups`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `genericarticlesgroups` (
  `assemblyGroup` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `designation` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `genericArticleId` bigint DEFAULT NULL,
  `masterDesignation` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `lang` varchar(5) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `usageDesignation` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Generic articles groups';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `journal_entry`
--

DROP TABLE IF EXISTS `journal_entry`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `journal_entry` (
  `id` int NOT NULL AUTO_INCREMENT,
  `merchant_id` int NOT NULL,
  `store_id` int NOT NULL,
  `posted_at` date NOT NULL,
  `source_type` varchar(32) NOT NULL COMMENT '''bill'',''purchase_bill'',''expense'',''bill_payment'',''pb_payment'',''manual''',
  `source_id` bigint unsigned DEFAULT NULL,
  `description` varchar(255) DEFAULT NULL,
  `created_by` int NOT NULL,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_je_merchant_date` (`merchant_id`,`posted_at`),
  KEY `idx_je_store_date` (`store_id`,`posted_at`),
  KEY `idx_je_source` (`source_type`,`source_id`),
  KEY `fk_je_user` (`created_by`),
  CONSTRAINT `fk_je_store` FOREIGN KEY (`store_id`) REFERENCES `store` (`id`),
  CONSTRAINT `fk_je_user` FOREIGN KEY (`created_by`) REFERENCES `user` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `journal_line`
--

DROP TABLE IF EXISTS `journal_line`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `journal_line` (
  `id` int NOT NULL AUTO_INCREMENT,
  `entry_id` int NOT NULL,
  `account_id` int NOT NULL,
  `debit` decimal(14,2) NOT NULL DEFAULT '0.00',
  `credit` decimal(14,2) NOT NULL DEFAULT '0.00',
  PRIMARY KEY (`id`),
  KEY `idx_jl_account` (`account_id`),
  KEY `idx_jl_entry` (`entry_id`),
  CONSTRAINT `fk_jl_account` FOREIGN KEY (`account_id`) REFERENCES `account` (`id`),
  CONSTRAINT `fk_jl_entry` FOREIGN KEY (`entry_id`) REFERENCES `journal_entry` (`id`) ON DELETE CASCADE,
  CONSTRAINT `chk_jl_nonzero` CHECK (((`debit` + `credit`) > 0)),
  CONSTRAINT `chk_jl_one_side` CHECK (((`debit` = 0) or (`credit` = 0)))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `keyvalues`
--

DROP TABLE IF EXISTS `keyvalues`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `keyvalues` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `keyId` varchar(10) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `keyTableId` bigint DEFAULT NULL,
  `keyValue` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `lang` varchar(5) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='All values for criterias';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `languages`
--

DROP TABLE IF EXISTS `languages`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `languages` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT 'hide',
  `languageCode` varchar(5) CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `languageName` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci,
  `lang` varchar(5) CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE,
  UNIQUE KEY `languages_id_uindex` (`id`) USING BTREE,
  KEY `lang` (`lang`) USING BTREE,
  KEY `languageCode` (`languageCode`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=1522 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Languages';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `legacy2generic`
--

DROP TABLE IF EXISTS `legacy2generic`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `legacy2generic` (
  `legacyArticleId` bigint unsigned NOT NULL,
  `genericArticleId` bigint DEFAULT NULL,
  `id` int NOT NULL AUTO_INCREMENT COMMENT 'hide',
  PRIMARY KEY (`id`) USING BTREE,
  UNIQUE KEY `legacyArticleId_2` (`legacyArticleId`,`genericArticleId`),
  KEY `legacyArticleId` (`legacyArticleId`) USING BTREE,
  KEY `genericArticleId` (`genericArticleId`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=6196251 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `linkagetargets`
--

DROP TABLE IF EXISTS `linkagetargets`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `linkagetargets` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `linkageTargetId` bigint NOT NULL,
  `linkageTargetType` varchar(15) CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `description` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `mfrId` bigint NOT NULL,
  `mfrName` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `mfrShortName` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `beginYearMonth` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `endYearMonth` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `lang` varchar(3) CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `subLinkageTargetType` varchar(15) CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `vehicleModelSeriesId` bigint NOT NULL,
  `vehicleModelSeriesName` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `rmiTypeId` bigint NOT NULL,
  `imageURL50` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `imageURL100` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `imageURL200` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `imageURL400` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `imageURL800` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `0` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `fuelMixtureFormationTypeKey` bigint NOT NULL,
  `fuelMixtureFormationType` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `driveTypeKey` bigint NOT NULL,
  `driveType` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `bodyStyleKey` bigint NOT NULL,
  `bodyStyle` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `valves` bigint NOT NULL,
  `fuelTypeKey` bigint NOT NULL,
  `fuelType` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `engineTypeKey` bigint NOT NULL,
  `engineType` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `horsePowerFrom` bigint NOT NULL,
  `horsePowerTo` bigint NOT NULL,
  `kiloWattsFrom` bigint NOT NULL,
  `kiloWattsTo` bigint NOT NULL,
  `cylinders` bigint NOT NULL,
  `capacityCC` bigint NOT NULL,
  `capacityLiters` double NOT NULL,
  `code` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `axleStyleKey` bigint NOT NULL,
  `axleStyle` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `axleTypeKey` bigint NOT NULL,
  `axleType` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `axleBodyKey` bigint NOT NULL,
  `axleBody` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `wheelMountingKey` bigint NOT NULL,
  `wheelMounting` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `axleLoadToKg` bigint NOT NULL,
  `brakeTypeKey` bigint NOT NULL,
  `brakeType` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `hmdMfrModelId` bigint NOT NULL,
  `hmdMfrModelName` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `aspirationKey` bigint NOT NULL,
  `aspiration` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `cylinderDesignKey` bigint NOT NULL,
  `cylinderDesign` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `coolingTypeKey` bigint NOT NULL,
  `coolingType` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `tonnage` bigint NOT NULL,
  `axleConfigurationKey` bigint NOT NULL,
  `axleConfiguration` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `axleLoadFromKg` bigint NOT NULL,
  PRIMARY KEY (`id`) USING BTREE,
  KEY `linkageTargetId_2` (`linkageTargetId`,`linkageTargetType`,`lang`) USING BTREE,
  KEY `idx_model_en` (`vehicleModelSeriesId`,`lang`),
  KEY `idx_vehicleModelSeriesId` (`vehicleModelSeriesId`),
  KEY `base_idx2` (`linkageTargetId`,`vehicleModelSeriesId`),
  KEY `linkageTargetIdx` (`linkageTargetId`),
  KEY `vehicleModelSeriesIdx` (`vehicleModelSeriesId`)
) ENGINE=InnoDB AUTO_INCREMENT=943318 DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Detailed information about vehicles';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `manufacturermotorids`
--

DROP TABLE IF EXISTS `manufacturermotorids`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `manufacturermotorids` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `motorId` bigint DEFAULT NULL,
  `manuId` bigint DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=33313 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Motor manufacturer IDs';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `manufacturers`
--

DROP TABLE IF EXISTS `manufacturers`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `manufacturers` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT 'hide',
  `manuId` bigint DEFAULT NULL,
  `manuName` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `linkingTargetType` varchar(5) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE,
  UNIQUE KEY `manufacturers_id_uindex` (`id`) USING BTREE,
  KEY `manuId` (`manuId`) USING BTREE,
  KEY `linkingTargetType` (`linkingTargetType`) USING BTREE,
  FULLTEXT KEY `manuName` (`manuName`)
) ENGINE=InnoDB AUTO_INCREMENT=3797 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Description of all manufacturers';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `modelseries`
--

DROP TABLE IF EXISTS `modelseries`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `modelseries` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT 'hide',
  `modelId` bigint DEFAULT NULL,
  `modelname` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `yearOfConstrTo` bigint DEFAULT NULL,
  `yearOfConstrFrom` bigint DEFAULT NULL,
  `linkingTargetType` varchar(5) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `manuId` bigint DEFAULT NULL,
  `start_year` int DEFAULT NULL,
  `end_year` int DEFAULT NULL,
  `model_name` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE,
  UNIQUE KEY `modelSeries_id_uindex` (`id`) USING BTREE,
  UNIQUE KEY `modelSeries_modelId_linkingTargetType_manuId_uindex` (`modelId`,`linkingTargetType`,`manuId`) USING BTREE,
  KEY `modelSeries_modelId_index` (`modelId`) USING BTREE,
  KEY `modelSeries_manuId_index` (`manuId`) USING BTREE,
  KEY `modelSeries_linkingTargetType_index` (`linkingTargetType`) USING BTREE,
  KEY `idx_all` (`manuId`,`modelname`,`yearOfConstrTo`,`yearOfConstrFrom`),
  KEY `base_idx` (`start_year`,`end_year`,`manuId`),
  KEY `base_idx2` (`modelname`,`manuId`,`start_year`,`end_year`),
  FULLTEXT KEY `modelname` (`modelname`),
  FULLTEXT KEY `model_name` (`model_name`)
) ENGINE=InnoDB AUTO_INCREMENT=34125 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Vehicle models - Linking target type:\r\nP: Passenger car\r\nO: Commercial vehicle\r\nM: Motor\r\nA: Axles\r\nK: Body type';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `modelseries_old`
--

DROP TABLE IF EXISTS `modelseries_old`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `modelseries_old` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT 'hide',
  `modelId` bigint DEFAULT NULL,
  `modelname` varchar(255) CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `yearOfConstrTo` bigint DEFAULT NULL,
  `yearOfConstrFrom` bigint DEFAULT NULL,
  `linkingTargetType` varchar(5) CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `manuId` bigint DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE,
  UNIQUE KEY `modelSeries_id_uindex` (`id`) USING BTREE,
  UNIQUE KEY `modelSeries_modelId_linkingTargetType_manuId_uindex` (`modelId`,`linkingTargetType`,`manuId`) USING BTREE,
  KEY `modelSeries_modelId_index` (`modelId`) USING BTREE,
  KEY `modelSeries_manuId_index` (`manuId`) USING BTREE,
  KEY `modelSeries_linkingTargetType_index` (`linkingTargetType`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=26025 DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Vehicle models - Linking target type:\r\nP: Passenger car\r\nO: Commercial vehicle\r\nM: Motor\r\nA: Axles\r\nK: Body type';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `motordetails`
--

DROP TABLE IF EXISTS `motordetails`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `motordetails` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `motorId` bigint DEFAULT NULL,
  `boreDiameter` bigint DEFAULT NULL,
  `charging` varchar(150) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `compressionFrom` bigint DEFAULT NULL,
  `constructionType` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `control` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `cooling` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `crankshafts` bigint DEFAULT NULL,
  `cylinder` bigint DEFAULT NULL,
  `cylinderCapacity` bigint DEFAULT NULL,
  `cylinderDesign` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `fuelPreperation` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `fuelType` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `litersTechFrom` bigint DEFAULT NULL,
  `manuId` bigint DEFAULT NULL,
  `manuText` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `motorCode` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `motorNumber` bigint DEFAULT NULL,
  `motorType` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `powerHP` bigint DEFAULT NULL,
  `powerKW` bigint DEFAULT NULL,
  `travel` bigint DEFAULT NULL,
  `valveControl` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `valves` bigint DEFAULT NULL,
  `lang` varchar(5) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `emissionStandard` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `rpmKwFrom` bigint DEFAULT NULL,
  `rpmTorqueFrom` bigint DEFAULT NULL,
  `sellsTerm` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `torqueFrom` bigint DEFAULT NULL,
  `ccmTaxFrom` bigint DEFAULT NULL,
  `powerHpTo` bigint DEFAULT NULL,
  `powerKwTo` bigint DEFAULT NULL,
  `rpmTorqueTo` bigint DEFAULT NULL,
  `rpmKwTo` bigint DEFAULT NULL,
  `litersTaxFrom` bigint DEFAULT NULL,
  `yearOfConstrFrom` bigint DEFAULT NULL,
  `compressionTo` bigint DEFAULT NULL,
  `torqueTo` bigint DEFAULT NULL,
  `yearOfConstrTo` bigint DEFAULT NULL,
  `litersTechTo` bigint DEFAULT NULL,
  `ccmTaxTo` bigint DEFAULT NULL,
  `litersTaxTo` bigint DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=33313 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Motor details';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `newarticles`
--

DROP TABLE IF EXISTS `newarticles`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `newarticles` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `articleId` bigint DEFAULT NULL,
  `articleNumber` varchar(100) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Unused info';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `notification_settings`
--

DROP TABLE IF EXISTS `notification_settings`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `notification_settings` (
  `id` int unsigned NOT NULL AUTO_INCREMENT,
  `user_id` int NOT NULL,
  `low_stock_alert` tinyint(1) NOT NULL DEFAULT '1',
  `low_stock_threshold` int unsigned NOT NULL DEFAULT '5',
  `pending_invoice_days` int unsigned NOT NULL DEFAULT '7',
  `new_order_alert` tinyint(1) NOT NULL DEFAULT '1',
  `payment_due_alert` tinyint(1) NOT NULL DEFAULT '1',
  `daily_summary` tinyint(1) NOT NULL DEFAULT '0',
  `email_enabled` tinyint(1) NOT NULL DEFAULT '0',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_notif_settings_user` (`user_id`),
  CONSTRAINT `fk_notif_settings_user` FOREIGN KEY (`user_id`) REFERENCES `user` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB AUTO_INCREMENT=27 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `notifications`
--

DROP TABLE IF EXISTS `notifications`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `notifications` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `user_id` int NOT NULL,
  `type` tinyint NOT NULL DEFAULT '0',
  `title` varchar(255) NOT NULL,
  `message` text NOT NULL,
  `is_read` tinyint(1) NOT NULL DEFAULT '0',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `fk_notif_user` (`user_id`),
  CONSTRAINT `fk_notif_user` FOREIGN KEY (`user_id`) REFERENCES `user` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `oem_number`
--

DROP TABLE IF EXISTS `oem_number`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `oem_number` (
  `id` int NOT NULL AUTO_INCREMENT,
  `number` varchar(255) NOT NULL,
  `articleId` bigint DEFAULT NULL,
  `clean_number` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `id_UNIQUE` (`id`) /*!80000 INVISIBLE */,
  UNIQUE KEY `number_UNIQUE` (`number`) /*!80000 INVISIBLE */,
  KEY `idx_article_id` (`articleId`),
  KEY `base_idx` (`number`,`articleId`),
  FULLTEXT KEY `full_text_search` (`number`),
  FULLTEXT KEY `clean_number` (`clean_number`)
) ENGINE=InnoDB AUTO_INCREMENT=21550894 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `oemnumbers`
--

DROP TABLE IF EXISTS `oemnumbers`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `oemnumbers` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT 'hide',
  `articleNumber` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `mfrId` bigint DEFAULT NULL,
  `assemblyGroupNodeId` bigint DEFAULT NULL,
  `legacyArticleId` bigint DEFAULT NULL,
  `lang` varchar(5) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `referenceTypeKey` varchar(25) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `referenceTypeDescription` varchar(200) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE,
  UNIQUE KEY `oemNumbers_id_uindex` (`id`) USING BTREE,
  UNIQUE KEY `articleNumber` (`articleNumber`,`mfrId`,`assemblyGroupNodeId`,`legacyArticleId`,`lang`,`referenceTypeKey`,`referenceTypeDescription`) USING BTREE,
  KEY `fk_oemNumbers_articles_1` (`legacyArticleId`) USING BTREE,
  KEY `fk_oemNumbers_articles_3` (`articleNumber`) USING BTREE,
  KEY `fk_oemNumbers_articles_4` (`mfrId`) USING BTREE,
  KEY `fk_oemNumbers_articles_6` (`assemblyGroupNodeId`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=1912176 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='OE article numbers';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `order_items`
--

DROP TABLE IF EXISTS `order_items`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `order_items` (
  `id` int unsigned NOT NULL AUTO_INCREMENT,
  `order_id` int unsigned NOT NULL,
  `part_id` bigint unsigned DEFAULT NULL,
  `part_name` varchar(255) COLLATE utf8mb4_unicode_ci NOT NULL,
  `quantity` int NOT NULL DEFAULT '1',
  `unit_price` decimal(12,2) NOT NULL DEFAULT '0.00',
  `line_total` decimal(12,2) NOT NULL DEFAULT '0.00',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_oi_order` (`order_id`),
  KEY `idx_oi_part` (`part_id`),
  CONSTRAINT `fk_oi_order` FOREIGN KEY (`order_id`) REFERENCES `orders` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `fk_oi_part` FOREIGN KEY (`part_id`) REFERENCES `product` (`id`),
  CONSTRAINT `chk_oi_price` CHECK ((`unit_price` >= 0)),
  CONSTRAINT `chk_oi_qty` CHECK ((`quantity` > 0)),
  CONSTRAINT `chk_oi_total` CHECK ((`line_total` >= 0))
) ENGINE=InnoDB AUTO_INCREMENT=13 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `orders`
--

DROP TABLE IF EXISTS `orders`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `orders` (
  `id` int unsigned NOT NULL AUTO_INCREMENT,
  `sequence_number` varchar(50) COLLATE utf8mb4_unicode_ci NOT NULL COMMENT 'e.g. ORD-001',
  `client_id` int unsigned DEFAULT NULL COMMENT 'FK to client — NULL for walk-in',
  `customer_name` varchar(255) COLLATE utf8mb4_unicode_ci DEFAULT NULL COMMENT 'Walk-in customer name',
  `store_id` int DEFAULT NULL COMMENT 'FK to store',
  `status` enum('pending','processing','completed','cancelled') COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'pending',
  `total` decimal(12,2) NOT NULL DEFAULT '0.00',
  `note` text COLLATE utf8mb4_unicode_ci,
  `created_by` int NOT NULL COMMENT 'FK to user who created',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_orders_seq` (`sequence_number`),
  KEY `idx_orders_client` (`client_id`),
  KEY `idx_orders_status` (`status`),
  KEY `idx_orders_store` (`store_id`),
  KEY `idx_orders_date` (`created_at`),
  KEY `idx_orders_created_by` (`created_by`),
  CONSTRAINT `fk_order_client` FOREIGN KEY (`client_id`) REFERENCES `client` (`id`) ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT `fk_order_store` FOREIGN KEY (`store_id`) REFERENCES `store` (`id`) ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT `fk_order_user` FOREIGN KEY (`created_by`) REFERENCES `user` (`id`) ON UPDATE CASCADE,
  CONSTRAINT `chk_order_seq` CHECK ((char_length(trim(`sequence_number`)) >= 1)),
  CONSTRAINT `chk_order_total` CHECK ((`total` >= 0))
) ENGINE=InnoDB AUTO_INCREMENT=17 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `product`
--

DROP TABLE IF EXISTS `product`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `product` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `article_id` int DEFAULT NULL,
  `store_id` int NOT NULL,
  `status` int NOT NULL DEFAULT '0',
  `shelf_number` varchar(45) DEFAULT NULL,
  `min_stock` int NOT NULL DEFAULT '5',
  `cost_price` decimal(12,2) NOT NULL DEFAULT '0.00',
  `price` decimal(12,2) NOT NULL,
  `quantity` decimal(10,3) NOT NULL,
  `is_deleted` tinyint(1) NOT NULL DEFAULT '0',
  `name` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `id_UNIQUE` (`article_id`,`store_id`) /*!80000 INVISIBLE */,
  KEY `idx_product_store_qty` (`store_id`,`quantity`),
  KEY `idx_product_store_price` (`store_id`,`price`),
  CONSTRAINT `ch_product_price` CHECK ((`price` > 0)),
  CONSTRAINT `ch_product_quantity` CHECK ((`quantity` >= 0))
) ENGINE=InnoDB AUTO_INCREMENT=285209073 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `purchase_bill`
--

DROP TABLE IF EXISTS `purchase_bill`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `purchase_bill` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `effective_date` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `payment_due_date` datetime DEFAULT NULL,
  `state` int NOT NULL DEFAULT '0',
  `discount` bigint NOT NULL DEFAULT '0',
  `supplier_id` int NOT NULL,
  `sequence_number` bigint unsigned DEFAULT NULL,
  `supplier_sequence_number` bigint unsigned DEFAULT NULL,
  `vat_sequence_number` bigint unsigned DEFAULT NULL,
  `store_id` int NOT NULL,
  `merchant_id` int NOT NULL,
  `pdf_link` varchar(255) DEFAULT NULL COMMENT 'file_key of the mandatory bill PDF',
  `payment_method` int NOT NULL DEFAULT '10' COMMENT 'ZATCA payment method: 10=Cash, 30=Credit, 42=Bank, 48=Card',
  `deliver_date` date DEFAULT NULL COMMENT 'Expected delivery date',
  `received_at` datetime DEFAULT NULL COMMENT 'When goods were confirmed received',
  `received_by` int DEFAULT NULL COMMENT 'FK to user.id — who confirmed receipt',
  `total_before_vat` decimal(12,2) NOT NULL DEFAULT '0.00',
  `total_vat` decimal(12,2) NOT NULL DEFAULT '0.00',
  `total` decimal(12,2) NOT NULL DEFAULT '0.00',
  `amount_paid` decimal(14,2) NOT NULL DEFAULT '0.00',
  `sequence_number_str` varchar(32) GENERATED ALWAYS AS (cast(`sequence_number` as char)) VIRTUAL,
  `supplier_sequence_number_str` varchar(64) GENERATED ALWAYS AS (cast(`supplier_sequence_number` as char)) VIRTUAL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_pb_supplier_seq` (`supplier_id`,`supplier_sequence_number`),
  UNIQUE KEY `uq_pb_sequence` (`sequence_number`),
  KEY `idx_pb_merchant_date` (`merchant_id`,`effective_date`),
  KEY `idx_pb_supplier_merchant` (`supplier_id`,`merchant_id`),
  KEY `idx_pb_payment_method` (`payment_method`),
  KEY `idx_pb_deliver_date` (`deliver_date`)
) ENGINE=InnoDB AUTO_INCREMENT=387 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `purchase_bill_attachments`
--

DROP TABLE IF EXISTS `purchase_bill_attachments`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `purchase_bill_attachments` (
  `id` int unsigned NOT NULL AUTO_INCREMENT,
  `purchase_bill_id` bigint unsigned NOT NULL,
  `file_key` varchar(100) COLLATE utf8mb4_unicode_ci NOT NULL,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_pba_file` (`purchase_bill_id`,`file_key`),
  KEY `fk_pba_file` (`file_key`),
  KEY `idx_pba_bill` (`purchase_bill_id`),
  CONSTRAINT `fk_pba_bill` FOREIGN KEY (`purchase_bill_id`) REFERENCES `purchase_bill` (`id`),
  CONSTRAINT `fk_pba_file` FOREIGN KEY (`file_key`) REFERENCES `uploaded_files` (`file_key`) ON DELETE CASCADE
) ENGINE=InnoDB AUTO_INCREMENT=5 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `purchase_bill_payment`
--

DROP TABLE IF EXISTS `purchase_bill_payment`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `purchase_bill_payment` (
  `id` int NOT NULL AUTO_INCREMENT,
  `purchase_bill_id` bigint unsigned NOT NULL,
  `date` datetime DEFAULT NULL,
  `paid_at` datetime NOT NULL,
  `amount` decimal(12,2) NOT NULL,
  `currency_id` int DEFAULT NULL,
  `payment_method` int DEFAULT NULL,
  `product_id` int DEFAULT NULL,
  `recorded_by` int DEFAULT NULL,
  `note` varchar(255) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `fk_pbp_pb_user` (`recorded_by`),
  KEY `idx_pbp_pb` (`purchase_bill_id`),
  KEY `idx_pbp_paid_at` (`paid_at`),
  CONSTRAINT `fk_pbp_pb_bill` FOREIGN KEY (`purchase_bill_id`) REFERENCES `purchase_bill` (`id`) ON DELETE CASCADE,
  CONSTRAINT `fk_pbp_pb_user` FOREIGN KEY (`recorded_by`) REFERENCES `user` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = utf8mb4 */ ;
/*!50003 SET character_set_results = utf8mb4 */ ;
/*!50003 SET collation_connection  = utf8mb4_0900_ai_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION' */ ;

--
-- Table structure for table `purchase_bill_product`
--

DROP TABLE IF EXISTS `purchase_bill_product`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `purchase_bill_product` (
  `id` int NOT NULL AUTO_INCREMENT,
  `product_id` bigint unsigned DEFAULT NULL,
  `bill_id` bigint unsigned NOT NULL,
  `vat` decimal(5,2) DEFAULT '15.00',
  `price` decimal(12,2) NOT NULL,
  `quantity` decimal(10,3) NOT NULL,
  `total_before_vat` decimal(12,2) GENERATED ALWAYS AS (round((`price` * `quantity`),2)) STORED,
  `vat_total` decimal(12,2) GENERATED ALWAYS AS (round(((`total_before_vat` * `vat`) / 100),2)) STORED,
  `total_including_vat` decimal(12,2) GENERATED ALWAYS AS (round((`total_before_vat` + `vat_total`),2)) STORED,
  `name` varchar(255) DEFAULT NULL,
  `type` tinyint GENERATED ALWAYS AS ((case when (`product_id` is not null) then 0 else 1 end)) STORED NOT NULL,
  PRIMARY KEY (`id`),
  KEY `fk_pbp_product_id` (`product_id`),
  CONSTRAINT `fk_pbp_product_id` FOREIGN KEY (`product_id`) REFERENCES `product` (`id`),
  CONSTRAINT `chpk_price` CHECK ((`price` > 0)),
  CONSTRAINT `chpk_quantity` CHECK ((`quantity` > 0))
) ENGINE=InnoDB AUTO_INCREMENT=580 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = utf8mb4 */ ;
/*!50003 SET character_set_results = utf8mb4 */ ;
/*!50003 SET collation_connection  = utf8mb4_0900_ai_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION' */ ;

--
-- Table structure for table `refresh_token`
--

DROP TABLE IF EXISTS `refresh_token`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `refresh_token` (
  `id` char(36) NOT NULL DEFAULT (uuid()),
  `user_id` int NOT NULL,
  `token_hash` varchar(64) NOT NULL,
  `device_name` varchar(100) DEFAULT NULL,
  `ip_address` varchar(45) DEFAULT NULL,
  `revoked` tinyint(1) NOT NULL DEFAULT '0',
  `expires_at` datetime NOT NULL,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_rt_user` (`user_id`),
  KEY `idx_rt_hash` (`token_hash`),
  KEY `idx_rt_expires` (`expires_at`),
  CONSTRAINT `fk_rt_user` FOREIGN KEY (`user_id`) REFERENCES `user` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `replacedbyarticles`
--

DROP TABLE IF EXISTS `replacedbyarticles`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `replacedbyarticles` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `articleNumber` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `dataSupplierId` bigint DEFAULT NULL,
  `mfrId` bigint DEFAULT NULL,
  `assemblyGroupNodeId` bigint DEFAULT NULL,
  `legacyArticleId` bigint DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=229424 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Replaced by articles';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `replacesarticles`
--

DROP TABLE IF EXISTS `replacesarticles`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `replacesarticles` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `articleNumber` varchar(250) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `dataSupplierId` bigint DEFAULT NULL,
  `mfrId` bigint DEFAULT NULL,
  `assemblyGroupNodeId` bigint DEFAULT NULL,
  `legacyArticleId` bigint DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=240835 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Replaces articles';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `searchindex`
--

DROP TABLE IF EXISTS `searchindex`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `searchindex` (
  `id` int NOT NULL AUTO_INCREMENT,
  `legacyArticleId` int unsigned DEFAULT NULL,
  `keywords` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci,
  PRIMARY KEY (`id`) USING BTREE,
  UNIQUE KEY `legacyArticleId` (`legacyArticleId`) USING BTREE,
  FULLTEXT KEY `keywords` (`keywords`)
) ENGINE=MyISAM AUTO_INCREMENT=5806070 DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Search index';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `settings`
--

DROP TABLE IF EXISTS `settings`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `settings` (
  `id` int unsigned NOT NULL AUTO_INCREMENT,
  `setting_key` varchar(100) COLLATE utf8mb4_unicode_ci NOT NULL,
  `value` text COLLATE utf8mb4_unicode_ci,
  `description` varchar(255) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `updated_by` int DEFAULT NULL,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_settings_key` (`setting_key`),
  KEY `fk_settings_user` (`updated_by`),
  CONSTRAINT `fk_settings_user` FOREIGN KEY (`updated_by`) REFERENCES `user` (`id`) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB AUTO_INCREMENT=14975 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `shortcuts`
--

DROP TABLE IF EXISTS `shortcuts`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `shortcuts` (
  `shortCutId` bigint DEFAULT NULL,
  `shortCutName` text CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci,
  `linkingTargetType` varchar(5) CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Shortcuts to vehicles main parts';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `stock_movements`
--

DROP TABLE IF EXISTS `stock_movements`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `stock_movements` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `product_id` bigint unsigned NOT NULL,
  `store_id` int NOT NULL COMMENT 'Denormalized from product.store_id for queries',
  `quantity` decimal(10,3) NOT NULL COMMENT 'Positive = stock in, Negative = stock out',
  `movement_type` varchar(20) COLLATE utf8mb4_unicode_ci NOT NULL,
  `reference_type` varchar(20) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `reference_id` bigint unsigned DEFAULT NULL,
  `item_id` int DEFAULT NULL COMMENT 'ID of the line item (bill_product.id or purchase_bill_product.id)',
  `reason` varchar(30) COLLATE utf8mb4_unicode_ci DEFAULT NULL COMMENT 'For adjustments: damaged, lost, expired, etc.',
  `note` text COLLATE utf8mb4_unicode_ci COMMENT 'Free text note for adjustments',
  `created_by` int DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_sm_product` (`product_id`,`created_at`),
  KEY `idx_sm_store` (`store_id`,`created_at`),
  KEY `idx_sm_reference` (`reference_type`,`reference_id`),
  KEY `idx_sm_type` (`movement_type`),
  KEY `idx_sm_created` (`created_at`),
  KEY `fk_sm_user` (`created_by`),
  CONSTRAINT `fk_sm_product` FOREIGN KEY (`product_id`) REFERENCES `product` (`id`),
  CONSTRAINT `fk_sm_store` FOREIGN KEY (`store_id`) REFERENCES `store` (`id`) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT `fk_sm_user` FOREIGN KEY (`created_by`) REFERENCES `user` (`id`) ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT `chk_sm_movement_type` CHECK ((`movement_type` in (_utf8mb4'purchase',_utf8mb4'sale',_utf8mb4'credit_note',_utf8mb4'adjustment',_utf8mb4'transfer_out',_utf8mb4'transfer_in',_utf8mb4'initial_balance',_utf8mb4'deletion'))),
  CONSTRAINT `chk_sm_reference_type` CHECK (((`reference_type` is null) or (`reference_type` in (_utf8mb4'purchase_bill',_utf8mb4'bill',_utf8mb4'credit_note',_utf8mb4'transfer',_utf8mb4'manual'))))
) ENGINE=InnoDB AUTO_INCREMENT=426 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `store`
--

DROP TABLE IF EXISTS `store`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `store` (
  `id` int NOT NULL AUTO_INCREMENT,
  `addressId` int DEFAULT NULL,
  `status` int NOT NULL DEFAULT '0',
  `company_id` int NOT NULL,
  `name` varchar(255) DEFAULT NULL,
  `branch_id` int unsigned DEFAULT NULL,
  `address_name` text,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `building_number` varchar(10) DEFAULT '',
  `street_name` varchar(100) DEFAULT '',
  `district` varchar(100) DEFAULT '',
  `city` varchar(100) DEFAULT '',
  `region` varchar(100) DEFAULT '',
  `postal_code` varchar(10) DEFAULT '',
  `additional_number` varchar(10) DEFAULT '',
  `unit_number` varchar(10) DEFAULT '',
  `country` varchar(3) DEFAULT 'SA',
  PRIMARY KEY (`id`),
  KEY `companyID_idx` (`company_id`),
  KEY `fk_store_branch` (`branch_id`),
  CONSTRAINT `companyID` FOREIGN KEY (`company_id`) REFERENCES `company` (`id`),
  CONSTRAINT `fk_store_branch` FOREIGN KEY (`branch_id`) REFERENCES `branches` (`id`) ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT `fk_stores_branch` FOREIGN KEY (`branch_id`) REFERENCES `branches` (`id`) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB AUTO_INCREMENT=54 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `supplier`
--

DROP TABLE IF EXISTS `supplier`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `supplier` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `company_id` int NOT NULL,
  `name` varchar(255) DEFAULT NULL,
  `address` varchar(255) DEFAULT NULL,
  `short_address` varchar(200) DEFAULT NULL,
  `phone_number` varchar(255) DEFAULT NULL,
  `number` varchar(255) DEFAULT NULL,
  `vat_number` varchar(255) DEFAULT NULL,
  `commercial_registration` varchar(10) DEFAULT NULL,
  `is_deleted` tinyint(1) DEFAULT '0',
  `bank_account` varchar(255) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `is_postpaid` tinyint(1) NOT NULL DEFAULT '0',
  `credit_limit` decimal(12,2) NOT NULL DEFAULT '0.00',
  `payment_terms_days` int NOT NULL DEFAULT '0',
  `preferred_payment_method` int NOT NULL DEFAULT '10' COMMENT 'Default ZATCA payment method for this supplier',
  `email` varchar(256) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `company_id` (`company_id`),
  KEY `idx_supplier_company` (`company_id`),
  KEY `idx_supplier_postpaid` (`is_postpaid`),
  KEY `idx_supplier_payment_method` (`preferred_payment_method`),
  CONSTRAINT `supplier_ibfk_1` FOREIGN KEY (`company_id`) REFERENCES `company` (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=253 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `tradenumbers`
--

DROP TABLE IF EXISTS `tradenumbers`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `tradenumbers` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `tradeNumber` varchar(150) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `legacyArticleId` bigint DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=1913184 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Spare Parts Trade Numbers';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `uploaded_files`
--

DROP TABLE IF EXISTS `uploaded_files`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `uploaded_files` (
  `id` int unsigned NOT NULL AUTO_INCREMENT,
  `file_key` varchar(100) COLLATE utf8mb4_unicode_ci NOT NULL COMMENT 'Random hex key + ext: abc123def456.pdf',
  `original_name` varchar(255) COLLATE utf8mb4_unicode_ci NOT NULL,
  `file_size` bigint unsigned NOT NULL DEFAULT '0',
  `mime_type` varchar(100) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `uploaded_by` int DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_file_key` (`file_key`),
  KEY `idx_uploaded_by` (`uploaded_by`),
  CONSTRAINT `fk_upload_user` FOREIGN KEY (`uploaded_by`) REFERENCES `user` (`id`) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB AUTO_INCREMENT=55 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `user`
--

DROP TABLE IF EXISTS `user`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `user` (
  `id` int NOT NULL AUTO_INCREMENT,
  `username` varchar(45) NOT NULL,
  `full_name` varchar(255) DEFAULT NULL,
  `password` varchar(100) NOT NULL,
  `company_id` int DEFAULT NULL,
  `email` varchar(255) DEFAULT NULL,
  `phone` varchar(20) DEFAULT NULL,
  `is_active` tinyint(1) NOT NULL DEFAULT '1',
  `last_login` datetime DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `role` enum('admin','manager','employee') NOT NULL DEFAULT 'employee',
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=20 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `user_permission`
--

DROP TABLE IF EXISTS `user_permission`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `user_permission` (
  `id` int NOT NULL AUTO_INCREMENT,
  `user_id` int NOT NULL,
  `resource` varchar(50) NOT NULL,
  `can_view` tinyint(1) NOT NULL DEFAULT '1',
  `can_add` tinyint(1) NOT NULL DEFAULT '0',
  `can_edit` tinyint(1) NOT NULL DEFAULT '0',
  `can_delete` tinyint(1) NOT NULL DEFAULT '0',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_user_resource` (`user_id`,`resource`),
  CONSTRAINT `fk_perm_user` FOREIGN KEY (`user_id`) REFERENCES `user` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB AUTO_INCREMENT=5 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `vehicleaxles`
--

DROP TABLE IF EXISTS `vehicleaxles`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `vehicleaxles` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `axleDescription` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `axleManufacturer` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `axleModel` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `axlePosition` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `lang` varchar(5) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `carId` bigint DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=55041 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Axles descriptions';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `vehicledetails`
--

DROP TABLE IF EXISTS `vehicledetails`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `vehicledetails` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `carId` bigint DEFAULT NULL,
  `ccmTech` bigint DEFAULT NULL,
  `constructionType` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `cylinder` bigint DEFAULT NULL,
  `cylinderCapacityCcm` bigint DEFAULT NULL,
  `cylinderCapacityLiter` bigint DEFAULT NULL,
  `fuelType` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `fuelTypeProcess` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `impulsionType` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `manuId` bigint DEFAULT NULL,
  `manuName` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `modId` bigint DEFAULT NULL,
  `modelName` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `motorType` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `powerHpFrom` bigint DEFAULT NULL,
  `powerHpTo` bigint DEFAULT NULL,
  `powerKwFrom` bigint DEFAULT NULL,
  `powerKwTo` bigint DEFAULT NULL,
  `typeName` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `typeNumber` bigint DEFAULT NULL,
  `valves` bigint DEFAULT NULL,
  `yearOfConstrFrom` bigint DEFAULT NULL,
  `yearOfConstrTo` bigint DEFAULT NULL,
  `lang` varchar(5) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `axisConfiguration` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `tonnage` bigint DEFAULT NULL,
  `brakeSystem` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  PRIMARY KEY (`id`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=64335 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Additional information about vehicle type';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `vehiclemotorcodes`
--

DROP TABLE IF EXISTS `vehiclemotorcodes`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `vehiclemotorcodes` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `carId` bigint NOT NULL,
  `motorCode` varchar(150) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  PRIMARY KEY (`id`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=76269 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Vehicle motor codes';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `vehicleprototypes`
--

DROP TABLE IF EXISTS `vehicleprototypes`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `vehicleprototypes` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `carId` bigint DEFAULT NULL,
  `prototype` varchar(250) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=54616 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Vehicles prototypes';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `vehiclesecondarytypes`
--

DROP TABLE IF EXISTS `vehiclesecondarytypes`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `vehiclesecondarytypes` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `subTypeDescription` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  `subTypeId` bigint DEFAULT NULL,
  `carId` bigint DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=2241 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Vehicle secondary types';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `vehicletrees`
--

DROP TABLE IF EXISTS `vehicletrees`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `vehicletrees` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT 'hide',
  `assemblyGroupNodeId` bigint DEFAULT NULL,
  `parentNodeId` bigint DEFAULT NULL,
  `sortNo` bigint DEFAULT NULL,
  `carId` bigint DEFAULT NULL,
  `linkingTargetType` varchar(5) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE,
  UNIQUE KEY `vehicleTrees_id_uindex` (`id`) USING BTREE,
  UNIQUE KEY `assemblyGroupNodeId_2` (`assemblyGroupNodeId`,`parentNodeId`,`sortNo`,`carId`,`linkingTargetType`) USING BTREE,
  KEY `parentNodeId` (`parentNodeId`) USING BTREE,
  KEY `sortNo` (`sortNo`) USING BTREE,
  KEY `carId` (`carId`) USING BTREE,
  KEY `linkingTargetType` (`linkingTargetType`) USING BTREE,
  KEY `assemblyGroupNodeId` (`assemblyGroupNodeId`,`parentNodeId`,`carId`,`linkingTargetType`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=25399489 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Vehicle parts search trees';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `vehiclewheelbases`
--

DROP TABLE IF EXISTS `vehiclewheelbases`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `vehiclewheelbases` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `axlePosition` varchar(150) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `wheelbase` bigint DEFAULT NULL,
  `wheelbaseId` bigint DEFAULT NULL,
  `carId` bigint DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE
) ENGINE=InnoDB AUTO_INCREMENT=99365 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='Vehicle wheel bases';
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `vin_cache`
--

DROP TABLE IF EXISTS `vin_cache`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `vin_cache` (
  `id` int NOT NULL AUTO_INCREMENT,
  `vin` varchar(20) NOT NULL,
  `data` json NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `number_UNIQUE` (`vin`)
) ENGINE=InnoDB AUTO_INCREMENT=45 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `zatca_submission`
--

DROP TABLE IF EXISTS `zatca_submission`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `zatca_submission` (
  `id` int NOT NULL AUTO_INCREMENT,
  `bill_id` bigint unsigned NOT NULL,
  `status` tinyint NOT NULL DEFAULT '0' COMMENT '0=pending,1=submitted,2=accepted,3=rejected,4=warning',
  `rejection_code` varchar(32) DEFAULT NULL,
  `rejection_msg` varchar(512) DEFAULT NULL,
  `submitted_at` datetime DEFAULT NULL,
  `cleared_at` datetime DEFAULT NULL,
  `response_xml` mediumtext,
  `retry_count` int NOT NULL DEFAULT '0',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_zatca_bill` (`bill_id`),
  KEY `idx_zatca_status` (`status`),
  KEY `idx_zatca_submitted` (`submitted_at`),
  CONSTRAINT `fk_zatca_bill` FOREIGN KEY (`bill_id`) REFERENCES `bill` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Final view structure for view `cash_voucher_summary`
--

/*!50001 DROP VIEW IF EXISTS `cash_voucher_summary`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb4 */;
/*!50001 SET character_set_results     = utf8mb4 */;
/*!50001 SET collation_connection      = utf8mb4_0900_ai_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY DEFINER */
/*!50001 VIEW `cash_voucher_summary` AS select `cash_voucher`.`voucher_type` AS `voucher_type`,`cash_voucher`.`state` AS `state`,`cash_voucher`.`merchant_id` AS `merchant_id`,count(0) AS `voucher_count`,sum(`cash_voucher`.`amount`) AS `total_amount`,date_format(`cash_voucher`.`effective_date`,'%Y-%m') AS `month` from `cash_voucher` group by `cash_voucher`.`voucher_type`,`cash_voucher`.`state`,`cash_voucher`.`merchant_id`,date_format(`cash_voucher`.`effective_date`,'%Y-%m') */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;

/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
/*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
/*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;

-- Dump completed on 2026-04-25 13:08:59
