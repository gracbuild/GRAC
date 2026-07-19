-- ============================================================================
-- ISO Controls Import to GRAC v1.0
-- Phase 2 -- Insert ISO repository controls + source_control_map rows
-- ============================================================================
-- Fill in the two parameters below before running.
-- @release_id : the grac_new.release row that represents the ISO release
--               these controls belong to. Get it from grac_new.release +
--               artifact + authority.
-- ============================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE @release_id       BIGINT = /* <FILL_IN> */ NULL;
DECLARE @artifact_id      BIGINT = (SELECT artifact_id FROM grac_new.release WHERE release_id = @release_id);
DECLARE @actor            NVARCHAR(100) = 'iso-import-v1.0';

IF @release_id IS NULL OR @artifact_id IS NULL
BEGIN
    RAISERROR('Set @release_id before running this script.', 16, 1);
    RETURN;
END
GO

DECLARE @release_id  BIGINT = /* <FILL_IN> */ NULL;
DECLARE @artifact_id BIGINT = (SELECT artifact_id FROM grac_new.release WHERE release_id = @release_id);
DECLARE @actor       NVARCHAR(100) = 'iso-import-v1.0';
IF @release_id IS NULL OR @artifact_id IS NULL BEGIN RAISERROR('Set @release_id.', 16, 1); RETURN; END;

-- Staging table: one row per control from the Excel.
IF OBJECT_ID('tempdb..#iso_ctrl') IS NOT NULL DROP TABLE #iso_ctrl;
CREATE TABLE #iso_ctrl (
    structure_node_id BIGINT       NOT NULL,
    control_code      NVARCHAR(60) NOT NULL,
    control_name      NVARCHAR(500) NOT NULL,
    control_description NVARCHAR(MAX) NULL
);

INSERT INTO #iso_ctrl (structure_node_id, control_code, control_name, control_description)
VALUES
(3, N'5.1', N'Policies for information security', N'Information security policy and topic-specific policies should be defined, approved by management, published, communicated to and acknowledged by relevant personnel and relevant interested parties, and reviewed at planned intervals and if significant changes occur.'),
(3, N'5.2', N'Information security roles and responsibilities', N'Information security roles and responsibilities should be defined and allocated according to the organization needs.'),
(3, N'5.3', N'Segregation of duties', N'Conflicting duties and conflicting areas of responsibility should be segregated.'),
(3, N'5.4', N'Management responsibilities', N'Management should require all personnel to apply information security in accordance with the established information security policy, topic-specific policies and procedures of the organization.'),
(3, N'5.5', N'Contact with authorities', N'The organization should establish and maintain contact with relevant authorities.'),
(3, N'5.6', N'Contact with special interest groups', N'The organization should establish and maintain contact with special interest groups or other specialist security forums and professional associations.'),
(3, N'5.7', N'Threat intelligence', N'Information relating to information security threats should be collected and analysed to produce threat intelligence.'),
(3, N'5.8', N'Information security in project management', N'Information security should be integrated into project management.'),
(3, N'5.9', N'Inventory of information and other associated assets', N'An inventory of information and other associated assets, including owners, should be developed and maintained.'),
(3, N'5.10', N'Acceptable use of information and other associated assets', N'Rules for the acceptable use and procedures for handling information and other associated assets should be identified, documented and implemented.'),
(3, N'5.11', N'Return of assets', N'Personnel and other interested parties as appropriate should return all the organization's assets in their possession upon change or termination of their employment, contract or agreement.'),
(3, N'5.12', N'Classification of information', N'Information should be classified according to the information security needs of the organization based on confidentiality, integrity, availability and relevant interested party requirements.'),
(3, N'5.13', N'Labelling of information', N'An appropriate set of procedures for information labelling should be developed and implemented in accordance with the information classification scheme adopted by the organization.'),
(3, N'5.14', N'Information transfer', N'Information transfer rules, procedures, or agreements should be in place for all types of transfer facilities within the organization and between the organization and other parties.'),
(3, N'5.15', N'Access control', N'Rules to control physical and logical access to information and other associated assets should be established and implemented based on business and information security requirements.'),
(3, N'5.16', N'Identity management', N'The full life cycle of identities should be managed.'),
(3, N'5.17', N'Authentication information', N'Allocation and management of authentication information should be controlled by a management process, including advising personnel on appropriate handling of authentication information.'),
(3, N'5.18', N'Access rights', N'Access rights to information and other associated assets should be provisioned, reviewed, modified and removed in accordance with the organization's topic-specific policy on and rules for access control.'),
(3, N'5.19', N'Information security in supplier relationships', N'Processes and procedures should be defined and implemented to manage the information security risks associated with the use of supplier's products or services.'),
(3, N'5.20', N'Addressing information security within supplier agreements', N'Relevant information security requirements should be established and agreed with each supplier based on the type of supplier relationship.'),
(3, N'5.21', N'Managing information security in the ICT supply chain', N'Processes and procedures should be defined and implemented to manage the information security risks associated with the ICT products and services supply chain.'),
(3, N'5.22', N'Monitoring, review and change management of supplier services', N'The organization should regularly monitor, review, evaluate and manage change in supplier information security practices and service delivery.'),
(3, N'5.23', N'Information security for use of cloud services', N'Processes for acquisition, use, management and exit from cloud services should be established in accordance with the organization's information security requirements.'),
(3, N'5.24', N'Information security incident management planning and preparation', N'The organization should plan and prepare for managing information security incidents by defining, establishing and communicating information security incident management processes, roles and responsibilities.'),
(3, N'5.25', N'Assessment and decision on information security events', N'The organization should assess information security events and decide if they are to be categorized as information security incidents.'),
(3, N'5.26', N'Response to information security incidents', N'Information security incidents should be responded to in accordance with the documented procedures.'),
(3, N'5.27', N'Learning from information security incidents', N'Knowledge gained from information security incidents should be used to strengthen and improve the information security controls.'),
(3, N'5.28', N'Collection of evidence', N'The organization should establish and implement procedures for the identification, collection, acquisition and preservation of evidence related to information security events.'),
(3, N'5.29', N'Information security during disruption', N'The organization should plan how to maintain information security at an appropriate level during disruption.'),
(3, N'5.30', N'ICT readiness for business continuity', N'ICT readiness should be planned, implemented, maintained and tested based on business continuity objectives and ICT continuity requirements.'),
(3, N'5.31', N'Legal, statutory, regulatory and contractual requirements', N'Legal, statutory, regulatory and contractual requirements relevant to information security and the organization's approach to meet these requirements should be identified, documented and kept up to date.'),
(3, N'5.32', N'Intellectual property rights', N'The organization should implement appropriate procedures to protect intellectual property rights.'),
(3, N'5.33', N'Protection of records', N'Records should be protected from loss, destruction, falsification, unauthorized access and unauthorized release.'),
(3, N'5.34', N'Privacy and protection of PII', N'The organization should identify and meet the requirements regarding the preservation of privacy and protection of PII according to applicable laws and regulations and contractual requirements.'),
(3, N'5.35', N'Independent review of information security', N'The organization's approach to managing information security and its implementation including people, processes and technologies should be reviewed independently at planned intervals, or when significant changes occur.'),
(3, N'5.36', N'Compliance with policies, rules and standards for information security', N'Compliance with the organization's information security policy, topic-specific policies, rules and standards should be regularly reviewed.'),
(3, N'5.37', N'Documented operating procedures', N'Operating procedures for information processing facilities should be documented and made available to personnel who need them.'),
(4, N'6.1', N'Screening', N'Background verification checks on all candidates to become personnel should be carried out prior to joining the organization and on an ongoing basis taking into consideration applicable laws, regulations and ethics and be proportional to the business requirements, the classification of the information to be accessed and the perceived risks.'),
(4, N'6.2', N'Terms and conditions of employment', N'The employment contractual agreements should state the personnel's and the organization's responsibilities for information security.'),
(4, N'6.3', N'Information security awareness, education and training', N'Personnel of the organization and relevant interested parties should receive appropriate information security awareness, education and training and regular updates of the organization''s information security policy, topic-specific policies and procedures, as relevant for their job function.'),
(4, N'6.4', N'Disciplinary process', N'A disciplinary process should be formalized and communicated to take actions against personnel and other relevant interested parties who have committed an information security policy violation.'),
(4, N'6.5', N'Responsibilities after termination or change of employment', N'Information security responsibilities and duties that remain valid after termination or change of employment should be defined, enforced and communicated to relevant personnel and other interested parties.'),
(4, N'6.6', N'Confidentiality or non-disclosure agreements', N'Confidentiality or non-disclosure agreements reflecting the organization's needs for the protection of information should be identified, documented, regularly reviewed and signed by personnel and other relevant interested parties.'),
(4, N'6.7', N'Remote working', N'Security measures should be implemented when personnel are working remotely to protect information accessed, processed or stored outside the organization's premises.'),
(4, N'6.8', N'Information security event reporting', N'The organization should provide a mechanism for personnel to report observed or suspected information security events through appropriate channels in a timely manner.'),
(5, N'7.1', N'Physical security perimeters', N'Security perimeters should be defined and used to protect areas that contain information and other associated assets.'),
(5, N'7.2', N'Physical entry', N'Secure areas should be protected by appropriate entry controls and access points.'),
(5, N'7.3', N'Securing offices, rooms and facilities', N'Physical security for offices, rooms and facilities should be designed and implemented.'),
(5, N'7.4', N'Physical security monitoring', N'Premises should be continuously monitored for unauthorized physical access.'),
(5, N'7.5', N'Protecting against physical and environmental threats', N'Protection against physical and environmental threats, such as natural disasters and other intentional or unintentional physical threats to infrastructure should be designed and implemented.'),
(5, N'7.6', N'Working in secure areas', N'Security measures for working in secure areas should be designed and implemented.'),
(5, N'7.7', N'Clear desk and clear screen', N'Clear desk rules for papers and removable storage media and clear screen rules for information processing facilities should be defined and appropriately enforced.'),
(5, N'7.8', N'Equipment siting and protection', N'Equipment should be sited securely and protected.'),
(5, N'7.9', N'Security of assets off-premises', N'Off-site assets should be protected.'),
(5, N'7.10', N'Storage media', N'Storage media should be managed through their life cycle of acquisition, use, transportation and disposal in accordance with the organization's classification scheme and handling requirements.'),
(5, N'7.11', N'Supporting utilities', N'Information processing facilities should be protected from power failures and other disruptions caused by failures in supporting utilities.'),
(5, N'7.12', N'Cabling security', N'Cables carrying power, data or supporting information services should be protected from interception, interference or damage.'),
(5, N'7.13', N'Equipment maintenance', N'Equipment should be maintained correctly to ensure availability, integrity and confidentiality of information.'),
(5, N'7.14', N'Secure disposal or re-use of equipment', N'Items of equipment containing storage media should be verified to ensure that any sensitive data and licensed software has been removed or securely overwritten prior to disposal or re-use.'),
(6, N'8.1', N'User endpoint devices', N'Information stored on, processed by or accessible via user endpoint devices should be protected.'),
(6, N'8.2', N'Privileged access rights', N'The allocation and use of privileged access rights should be restricted and managed.'),
(6, N'8.3', N'Information access restriction', N'Access to information and other associated assets should be restricted in accordance with the established topic-specific policy on access control.'),
(6, N'8.4', N'Access to source code', N'Read and write access to source code, development tools and software libraries should be appropriately managed.'),
(6, N'8.5', N'Secure authentication', N'Secure authentication technologies and procedures should be implemented based on information access restrictions and the topic-specific policy on access control.'),
(6, N'8.6', N'Capacity management', N'The use of resources should be monitored and adjusted in line with current and expected capacity requirements.'),
(6, N'8.7', N'Protection against malware', N'Protection against malware should be implemented and supported by appropriate user awareness.'),
(6, N'8.8', N'Management of technical vulnerabilities', N'Information about technical vulnerabilities of information systems in use should be obtained, the organization's exposure to such vulnerabilities should be evaluated and appropriate measures should be taken.'),
(6, N'8.9', N'Configuration management', N'Configurations, including security configurations, of hardware, software, services and networks should be established, documented, implemented, monitored and reviewed.'),
(6, N'8.10', N'Information deletion', N'Information stored in information systems, devices or in any other storage media should be deleted when no longer required.'),
(6, N'8.11', N'Data masking', N'Data masking should be used in accordance with the organization's topic-specific policy on access control and other related topic-specific policies, and business requirements, taking applicable legislation into consideration.'),
(6, N'8.12', N'Data leakage prevention', N'Data leakage prevention measures should be applied to systems, networks and any other devices that process, store or transmit sensitive information.'),
(6, N'8.13', N'Information backup', N'Backup copies of information, software and systems should be maintained and regularly tested in accordance with the agreed topic-specific policy on backup.'),
(6, N'8.14', N'Redundancy of information processing facilities', N'Information processing facilities should be implemented with redundancy sufficient to meet availability requirements.'),
(6, N'8.15', N'Logging', N'Logs that record activities, exceptions, faults and other relevant events should be produced, stored, protected and analysed.'),
(6, N'8.16', N'Monitoring activities', N'Networks, systems and applications should be monitored for anomalous behaviour and appropriate actions taken to evaluate potential information security incidents.'),
(6, N'8.17', N'Clock synchronization', N'The clocks of information processing systems used by the organization should be synchronized to approved time sources.'),
(6, N'8.18', N'Use of privileged utility programs', N'The use of utility programs that can be capable of overriding system and application controls should be restricted and tightly controlled.'),
(6, N'8.19', N'Installation of software on operational systems', N'Procedures and measures should be implemented to securely manage software installation on operational systems.'),
(6, N'8.20', N'Networks security', N'Networks and network devices should be secured, managed and controlled to protect information in systems and applications.'),
(6, N'8.21', N'Security of network services', N'Security mechanisms, service levels and service requirements of network services should be identified, implemented and monitored.'),
(6, N'8.22', N'Segregation of networks', N'Groups of information services, users and information systems should be segregated in the organization's networks.'),
(6, N'8.23', N'Web filtering', N'Access to external websites should be managed to reduce exposure to malicious content.'),
(6, N'8.24', N'Use of cryptography', N'Rules for the effective use of cryptography, including cryptographic key management, should be defined and implemented.'),
(6, N'8.25', N'Secure development life cycle', N'Rules for the secure development of software and systems should be established and applied.'),
(6, N'8.26', N'Application security requirements', N'Information security requirements should be identified, specified and approved when developing or acquiring applications.'),
(6, N'8.27', N'Secure system architecture and engineering principles', N'Principles for engineering secure systems should be established, documented, maintained and applied to any information system development activities.'),
(6, N'8.28', N'Secure coding', N'Secure coding principles should be applied to software development.'),
(6, N'8.29', N'Security testing in development and acceptance', N'Security testing processes should be defined and implemented in the development life cycle.'),
(6, N'8.30', N'Outsourced development', N'The organization should direct, monitor and review the activities related to outsourced system development.'),
(6, N'8.31', N'Separation of development, test and production environments', N'Development, testing and production environments should be separated and secured.'),
(6, N'8.32', N'Change management', N'Changes to information processing facilities and information systems should be subject to change management procedures.'),
(6, N'8.33', N'Test information', N'Test information should be appropriately selected, protected and managed.'),
(6, N'8.34', N'Protection of information systems during audit testing', N'Audit tests and other assurance activities involving assessment of operational systems should be planned and agreed between the tester and appropriate management.');

BEGIN TRAN;

-- 2a. INSERT controls (skip codes already present so re-runs are safe).
INSERT INTO grac_new.control (control_code, control_name, description, status, entered_by, entered_dt)
SELECT s.control_code, s.control_name, s.control_description, N'Active', @actor, SYSUTCDATETIME()
FROM #iso_ctrl s
WHERE NOT EXISTS (
    SELECT 1 FROM grac_new.control c WHERE c.control_code = s.control_code AND c.status = N'Active'
);

-- 2b. INSERT source_control_map rows linking each control to its
--     Source Structure Node for the target release.
INSERT INTO grac_new.source_control_map (release_id, artifact_id, structure_node_id, control_id, status, entered_by, entered_dt)
SELECT @release_id, @artifact_id, s.structure_node_id, c.control_id, N'Active', @actor, SYSUTCDATETIME()
FROM #iso_ctrl s
JOIN grac_new.control c ON c.control_code = s.control_code AND c.status = N'Active'
WHERE NOT EXISTS (
    SELECT 1 FROM grac_new.source_control_map m
    WHERE m.release_id = @release_id AND m.structure_node_id = s.structure_node_id AND m.control_id = c.control_id
);

COMMIT;

SELECT 'Phase 2 controls loaded' AS Result,
       (SELECT COUNT(*) FROM #iso_ctrl) AS ExcelControls,
       (SELECT COUNT(*) FROM grac_new.source_control_map m
        JOIN grac_new.source_structure_node n ON n.structure_node_id = m.structure_node_id AND n.release_id = @release_id
        WHERE m.status = N'Active') AS MappedForRelease;
GO
