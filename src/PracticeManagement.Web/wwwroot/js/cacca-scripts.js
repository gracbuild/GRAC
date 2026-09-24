// Function to bind custom search to DataTable
function bindCustomSearchToDataTable(
  tableSelector,
  inputSelector = "#customSearchBox"
) {
  const table = $(tableSelector).DataTable();
  console.log(
    "Custom search bound to:",
    inputSelector,
    "Table instance:",
    table
  );

  $(inputSelector).on("keyup", function () {
    console.log("Searching for:", this.value);
    table.search(this.value).draw();
  });
}
async function APIHttpPost(
  url,
  data,
  success,
  AuthorizationToken,
  hideNoDataError = false
) {
  try {
    const previousToken = AuthorizationToken;
    // console.log("APIHttpPost calling with token ", AuthorizationToken, url);
    const response = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: AuthorizationToken,
      },
      body: JSON.stringify(data),
    });

    if (!response.ok) {
      $("#Loader").hide();

      if (response.status === 403) {
        swal("", "Please try again", "error");
      } else {
        swal(
          "",
          "Please check your internet connection and try again",
          "error"
        );
      }

      return;
    }

    const resp = await response.json();
    //  console.log("resp", url, resp.Status, Token, resp.responseStr);

    if (resp.status === "SUCCESS") {
      try {
        const responseStr = Decrypt(resp.responseStr, Token);
        //console.log("responseStr", { resp, Token });
        let Response = JSON.parse(responseStr);

        if (Response.ResponseStr && typeof Response.ResponseStr === "string") {
          Response = JSON.parse(Response.ResponseStr);
        }

        if (Response.NToken) {
          // console.log("New token:", Response.NToken);
          UpdateToken(Response.NToken);
        }

        success(resp, Response);
      } catch (e) {
        console.error("Response parse error:", e);
        $("#Loader").hide();
        swal("", "Invalid server response", "error");
      }
    } else {
      CaccaHandleAPIError(resp, hideNoDataError, previousToken, url, data);
    }
  } catch (error) {
    $("#Loader").hide();
    console.error("Fetch error:", error);
    swal("", "Something went wrong. Please try again later.", "error");
  }
}

function CaccaHandleAPIError(
  Res,
  hideNoDataError = false,
  previousToken,
  url,
  data
) {
  try {
    if (Res.status == "AUTHERROR") {
      console.log("Authentication Error", Res.responseStr);
      let responseStr, Response;
      try {
        responseStr = Res.responseStr;
        Response = JSON.parse(responseStr);
      } catch {}
      var goToLogin = function () { window.location = DomainURL + "/Login"; };
      swal(
        {
          title: (Response && Response.Title) || "Authentication Error",
          text: (Response && Response.Message) || "Session expired. Please login again.",
          type: "warning",
          timer: 2500,
        },
        goToLogin
      );
      // Auto-redirect to the login page even if the dialog closes on its
      // timer or the user never clicks -- the session has ended.
      setTimeout(goToLogin, 2600);
    } else if (Res.status == "INFO") {
      var responseStr = Decrypt(Res.responseStr, Token);
      var Response = JSON.parse(JSON.parse(responseStr).ResponseStr);
      if (Response.Message) {
        swal({
          title: Response.Title || "Information",
          text: Response.Message,
          type: "info",
        });
      }
    } else if (Res.status == "FAIL") {
      // console.log("Res", { Res, Token });
      let responseStr,Response;
      try {
        responseStr = Decrypt(Res.responseStr, Token);
        Response = JSON.parse(JSON.parse(responseStr).ResponseStr);
      } catch {
        //redirect to login
        window.location = DomainURL + "/Login";
        return;
      }
     //  console.log("Response", Response, url, data);
      if (Response?.Message == "No Data Found" && hideNoDataError) {
      } else {
        swal("Error", Response?.Message || "Error", "error");
      }
      try {
        const decryptedData = Decrypt(data.requestStr, previousToken);
        console.error("API Failed Debug", {
          URL: url,
          Data: data,
          Token: previousToken,
          DecryptedResponse: JSON.parse(decryptedData),
        });
      } catch {
        console.error("API Failed Debug", {
          URL: url,
          Data: data,
          Token: previousToken,
        });
      }
    } else {
      swal("Error", Res.responseStr, "error");
    }
  } catch (e) {
    console.error("Error:", e);
    swal("Error", "Error", "error");
  }
  $("#Loader").hide();
}

// Generic Right Sidebar System
var CaccaSidebar = {
  currentSidebar: null,

  // Initialize sidebar system
  init: function () {
    // Handle Escape key for all sidebars
    $(document).keydown(function (e) {
      if (e.key === "Escape" && CaccaSidebar.currentSidebar) {
        CaccaSidebar.close();
      }
    });
  },

  // Open a sidebar with data
  open: function (sidebarId, data, options) {
    options = options || {};

    // Close any existing sidebar first
    if (CaccaSidebar.currentSidebar) {
      CaccaSidebar.close();
    }

    var $sidebar = $("#" + sidebarId);
    var $overlay = $("#" + sidebarId + "Overlay");

    if ($sidebar.length === 0) {
      console.error("Sidebar not found: " + sidebarId);
      return;
    }

    // Populate sidebar with data if populate function is provided
    if (options.populate && typeof options.populate === "function") {
      options.populate(data);
    }

    // Show overlay and sidebar
    $overlay.addClass("show");
    $sidebar.addClass("show");

    // Prevent body scroll
    $("body").css("overflow", "hidden");

    // Store current sidebar reference
    CaccaSidebar.currentSidebar = sidebarId;

    // Setup close handlers for this specific sidebar
    CaccaSidebar.setupCloseHandlers(sidebarId);

    // Trigger open callback if provided
    if (options.onOpen && typeof options.onOpen === "function") {
      options.onOpen(data);
    }
  },

  // Close the current sidebar
  close: function () {
    if (!CaccaSidebar.currentSidebar) return;

    var $sidebar = $("#" + CaccaSidebar.currentSidebar);
    var $overlay = $("#" + CaccaSidebar.currentSidebar + "Overlay");

    $overlay.removeClass("show");
    $sidebar.removeClass("show");

    // Re-enable body scroll
    $("body").css("overflow", "auto");

    // Clear current sidebar reference
    CaccaSidebar.currentSidebar = null;

    // Remove specific event handlers
    $overlay.off("click.sidebar");
    $sidebar.find(".cacca-sidebar-close").off("click.sidebar");
  },

  // Setup close handlers for a specific sidebar
  setupCloseHandlers: function (sidebarId) {
    var $sidebar = $("#" + sidebarId);
    var $overlay = $("#" + sidebarId + "Overlay");

    // Close on overlay click
    $overlay.on("click.sidebar", function () {
      CaccaSidebar.close();
    });

    // Close on close button click
    $sidebar.find(".cacca-sidebar-close").on("click.sidebar", function () {
      CaccaSidebar.close();
    });
  },

  // Make table rows clickable for sidebar
  makeTableClickable: function (tableId, options) {
    options = options || {};

    var $table = $("#" + tableId);

    // Add clickable class and cursor
    $table.find("tbody tr").addClass("clickable");

    // Remove existing click handlers
    $table.find("tbody").off("click.tablerow", "tr");

    // Add click handler
    $table.find("tbody").on("click.tablerow", "tr", function (e) {
      // Don't trigger if clicking on dropdown or other interactive elements
      if (
        $(e.target).closest(".dropdown, .dropdown-menu, .btn, button, a")
          .length > 0
      ) {
        return;
      }

      var rowData = null;

      // Get row data from DataTable if available
      if ($.fn.DataTable.isDataTable("#" + tableId)) {
        rowData = $("#" + tableId)
          .DataTable()
          .row(this)
          .data();
      }

      // Trigger callback with row data
      if (options.onClick && typeof options.onClick === "function") {
        options.onClick(rowData, this);
      }
    });
  },
};

// Sidebar State Persistence
var SidebarPersistence = {
  // Storage key for sidebar state
  STORAGE_KEY: "cacca_sidebar_collapsed",

  // Initialize sidebar persistence
  init: function () {
    if (window.disableSidebarPersistence) {
      try { localStorage.removeItem(this.STORAGE_KEY); } catch (e) {}
      return;
    }
    this.bindEvents();
  },

  // Save sidebar state to localStorage
  saveSidebarState: function (isCollapsed) {
    if (window.disableSidebarPersistence) return;
    try {
      localStorage.setItem(this.STORAGE_KEY, JSON.stringify(isCollapsed));
    } catch (e) {
      console.warn("Failed to save sidebar state to localStorage:", e);
    }
  },

  // Bind events to save state when sidebar is toggled
  bindEvents: function () {
    var self = this;

    // Listen for AdminLTE pushmenu events. Persist ONLY a deliberate
    // hamburger press (window.__pmSidebarUserToggle, set in _Layout on the
    // button's pointerdown). AdminLTE fires these same events for its
    // automatic width<=992 / resize collapse; persisting those used to pin
    // the sidebar collapsed for every later page load until re-login.
    $(document).on(
      "collapsed.lte.pushmenu",
      '[data-widget="pushmenu"]',
      function () {
        if (window.__pmSidebarUserToggle) self.saveSidebarState(true);
      }
    );

    $(document).on(
      "shown.lte.pushmenu",
      '[data-widget="pushmenu"]',
      function () {
        if (window.__pmSidebarUserToggle) self.saveSidebarState(false);
      }
    );
  },
};

// Initialize sidebar system when document is ready
$(document).ready(function () {
  CaccaSidebar.init();
  SidebarPersistence.init();
});

// ============== SEARCHABLE DROPDOWN COMPONENT ==============
/**
 * Generic Searchable Dropdown Component
 * Converts a regular select dropdown into a searchable dropdown
 *
 * Usage:
 *   CaccaSearchableDropdown.init({
 *     selectId: '#mySelect',
 *     placeholder: 'Select an option',
 *     searchPlaceholder: 'Search...',
 *     onSelect: function(value, text) { ... }
 *   });
 */
var CaccaSearchableDropdown = {
  instances: {},

  /**
   * Initialize a searchable dropdown
   * @param {Object} options - Configuration options
   * @param {string} options.selectId - ID or selector of the select element
   * @param {string} options.placeholder - Placeholder text when nothing is selected
   * @param {string} options.searchPlaceholder - Placeholder for search input
   * @param {Function} options.onSelect - Callback when an option is selected
   * @param {string} options.containerClass - Additional CSS class for container
   */
  init: function (options) {
    if (!options || !options.selectId) {
      console.error("CaccaSearchableDropdown: selectId is required");
      return;
    }

    var $select = $(options.selectId);
    if ($select.length === 0) {
      console.error(
        "CaccaSearchableDropdown: Select element not found:",
        options.selectId
      );
      return;
    }

    // Don't initialize if already initialized
    if (this.instances[options.selectId]) {
      console.warn(
        "CaccaSearchableDropdown: Already initialized for",
        options.selectId
      );
      return;
    }

    var instanceId = options.selectId.replace("#", "").replace(".", "");
    var containerId = "cacca-searchable-" + instanceId;
    var headerId = containerId + "-header";
    var contentId = containerId + "-content";
    var searchId = containerId + "-search";
    var listId = containerId + "-list";

    // Hide original select
    $select.hide();

    // Create container HTML
    var containerHtml = `
      <div class="cacca-searchable-dropdown-container" id="${containerId}">
        <div class="cacca-searchable-dropdown-header" id="${headerId}">
          <span class="cacca-searchable-dropdown-placeholder">${
            options.placeholder || "Select an option"
          }</span>
        </div>
        <div class="cacca-searchable-dropdown-content" id="${contentId}" style="display: none;">
          <div class="cacca-searchable-dropdown-search">
            <i class="fas fa-search cacca-searchable-search-icon"></i>
            <input type="text" class="cacca-searchable-search-input" id="${searchId}" placeholder="${
      options.searchPlaceholder || "Search..."
    }">
          </div>
          <div class="cacca-searchable-dropdown-divider"></div>
          <div class="cacca-searchable-dropdown-list" id="${listId}">
            <!-- Options will be populated here -->
          </div>
        </div>
      </div>
    `;

    // Insert container after select
    $select.after(containerHtml);

    var $container = $("#" + containerId);
    var $header = $("#" + headerId);
    var $content = $("#" + contentId);
    var $search = $("#" + searchId);
    var $list = $("#" + listId);
    var $placeholder = $header.find(".cacca-searchable-dropdown-placeholder");

    // Populate options
    this.populateOptions(
      $select,
      $list,
      $placeholder,
      options.placeholder || "Select an option"
    );

    // Store instance
    this.instances[options.selectId] = {
      selectId: options.selectId,
      $select: $select,
      $container: $container,
      $header: $header,
      $content: $content,
      $search: $search,
      $list: $list,
      $placeholder: $placeholder,
      onSelect: options.onSelect || null,
      placeholder: options.placeholder || "Select an option",
    };

    // Setup event handlers
    this.setupEventHandlers(options.selectId);
  },

  /**
   * Populate dropdown options from select element
   */
  populateOptions: function ($select, $list, $placeholder, defaultPlaceholder) {
    $list.empty();
    var hasSelection = false;

    $select.find("option").each(function () {
      var $option = $(this);
      var value = $option.val();
      var text = $option.text();
      var isSelected = $option.prop("selected");
      var isPlaceholder = !value || value === "";

      if (isPlaceholder) {
        return; // Skip placeholder options
      }

      if (isSelected) {
        hasSelection = true;
        $placeholder
          .text(text)
          .removeClass("cacca-searchable-placeholder-empty");
      }

      var optionHtml = `
        <button type="button" class="cacca-searchable-dropdown-item" data-value="${value}" data-text="${text}">
          ${text}
        </button>
      `;
      $list.append(optionHtml);
    });

    if (!hasSelection) {
      $placeholder
        .text(defaultPlaceholder)
        .addClass("cacca-searchable-placeholder-empty");
    }
  },

  /**
   * Setup event handlers for a dropdown instance
   */
  setupEventHandlers: function (selectId) {
    var instance = this.instances[selectId];
    if (!instance) return;

    var self = this;
    var $header = instance.$header;
    var $content = instance.$content;
    var $search = instance.$search;
    var $list = instance.$list;
    var $select = instance.$select;
    var $placeholder = instance.$placeholder;

    // Toggle dropdown on header click
    $header.on("click", function (e) {
      e.stopPropagation();
      self.toggleDropdown(selectId);
    });

    // Search functionality
    $search.on("input", function () {
      var searchTerm = $(this).val().toLowerCase();
      self.filterOptions(selectId, searchTerm);
    });

    // Select option
    $list.on("click", ".cacca-searchable-dropdown-item", function (e) {
      e.stopPropagation();
      var value = $(this).data("value");
      var text = $(this).data("text");
      self.selectOption(selectId, value, text);
    });

    // Close dropdown when clicking outside
    $(document).on("click.searchableDropdown", function (e) {
      if (!$(e.target).closest(instance.$container).length) {
        self.closeDropdown(selectId);
      }
    });

    // Handle keyboard navigation
    $search.on("keydown", function (e) {
      if (e.key === "Escape") {
        self.closeDropdown(selectId);
        $header.focus();
      } else if (e.key === "Enter") {
        e.preventDefault();
        var $firstVisible = $list
          .find(".cacca-searchable-dropdown-item:visible")
          .first();
        if ($firstVisible.length) {
          var value = $firstVisible.data("value");
          var text = $firstVisible.data("text");
          self.selectOption(selectId, value, text);
        }
      }
    });
  },

  /**
   * Toggle dropdown open/close
   */
  toggleDropdown: function (selectId) {
    var instance = this.instances[selectId];
    if (!instance) return;

    var isOpen = instance.$content.is(":visible");

    // Close all other dropdowns
    this.closeAllDropdowns();

    if (!isOpen) {
      this.openDropdown(selectId);
    } else {
      this.closeDropdown(selectId);
    }
  },

  /**
   * Open dropdown
   */
  openDropdown: function (selectId) {
    var instance = this.instances[selectId];
    if (!instance) return;

    instance.$content.show();
    instance.$header.addClass("active");
    instance.$search.val("");
    instance.$search.focus();
    this.filterOptions(selectId, "");
  },

  /**
   * Close dropdown
   */
  closeDropdown: function (selectId) {
    var instance = this.instances[selectId];
    if (!instance) return;

    instance.$content.hide();
    instance.$header.removeClass("active");
    instance.$search.val("");
  },

  /**
   * Close all dropdowns
   */
  closeAllDropdowns: function () {
    var self = this;
    Object.keys(this.instances).forEach(function (selectId) {
      self.closeDropdown(selectId);
    });
  },

  /**
   * Filter options based on search term
   */
  filterOptions: function (selectId, searchTerm) {
    var instance = this.instances[selectId];
    if (!instance) return;

    var $items = instance.$list.find(".cacca-searchable-dropdown-item");

    if (searchTerm == null || searchTerm === "") {
      $items.show();
      return;
    }

    var searchLower = String(searchTerm).toLowerCase().trim();

    $items.each(function () {
      var $item = $(this);
      var text = ($item.data("text") != null ? String($item.data("text")) : "").toLowerCase();
      if (text.indexOf(searchLower) !== -1) {
        $item.show();
      } else {
        $item.hide();
      }
    });
  },

  /**
   * Select an option
   */
  selectOption: function (selectId, value, text) {
    var instance = this.instances[selectId];
    if (!instance) return;

    // Update select value
    instance.$select.val(value).trigger("change");

    // Update placeholder text
    instance.$placeholder
      .text(text)
      .removeClass("cacca-searchable-placeholder-empty");

    // Close dropdown
    this.closeDropdown(selectId);

    // Trigger callback
    if (instance.onSelect && typeof instance.onSelect === "function") {
      instance.onSelect(value, text);
    }
  },

  /**
   * Update options dynamically
   */
  updateOptions: function (selectId, options) {
    var instance = this.instances[selectId];
    if (!instance) return;

    var $select = instance.$select;
    $select.empty();

    if (options && options.length > 0) {
      options.forEach(function (option) {
        var $option = $("<option></option>")
          .attr("value", option.value)
          .text(option.text);
        $select.append($option);
      });
    }

    // Repopulate dropdown
    this.populateOptions(
      $select,
      instance.$list,
      instance.$placeholder,
      instance.placeholder
    );
  },

  /**
   * Get selected value
   */
  getValue: function (selectId) {
    var instance = this.instances[selectId];
    if (!instance) return null;
    return instance.$select.val();
  },

  /**
   * Set selected value
   */
  setValue: function (selectId, value) {
    var instance = this.instances[selectId];
    if (!instance) return;

    instance.$select.val(value).trigger("change");
    var $selectedOption = instance.$select.find("option:selected");
    if ($selectedOption.length) {
      var text = $selectedOption.text();
      instance.$placeholder
        .text(text)
        .removeClass("cacca-searchable-placeholder-empty");
    }
  },

  /**
   * Destroy instance
   */
  destroy: function (selectId) {
    var instance = this.instances[selectId];
    if (!instance) return;

    instance.$container.remove();
    instance.$select.show();
    delete this.instances[selectId];
  },
};

// ============== ORGANIZATION SELECTION PERSISTENCE ==============
/**
 * Common utility functions for saving and retrieving the last selected organization
 * across all pages (Organization, RiskTreatment, RiskRegister, etc.)
 *
 * Uses a single localStorage key so all pages share the same selection.
 */
var CaccaOrganizationPersistence = {
  // Storage key for selected organization (shared across all pages)
  STORAGE_KEY: "cacca_selected_organization",

  /**
   * Save the selected organization ID to localStorage
   * @param {string|number} customerId - The organization/customer ID to save
   */
  saveSelectedOrganization: function (customerId) {
    try {
      if (customerId) {
        localStorage.setItem(this.STORAGE_KEY, String(customerId));
      } else {
        localStorage.removeItem(this.STORAGE_KEY);
      }
    } catch (e) {
      console.error("Error saving organization selection:", e);
    }
  },

  /**
   * Get the saved organization ID from localStorage
   * @returns {string|null} The saved organization ID or null if not found
   */
  getSavedOrganization: function () {
    try {
      return localStorage.getItem(this.STORAGE_KEY);
    } catch (e) {
      console.error("Error reading organization selection:", e);
      return null;
    }
  },

  /**
   * Check if a customer ID is valid (exists in the organizations list)
   * @param {string|number} customerId - The customer ID to validate
   * @param {Array} orgs - Array of organization objects with CustomerId property
   * @returns {boolean} True if the ID exists in the organizations list
   */
  isValidOrganizationId: function (customerId, orgs) {
    if (!customerId || !orgs || !Array.isArray(orgs)) {
      return false;
    }
    return orgs.some(function (org) {
      return String(org.CustomerId) === String(customerId);
    });
  },

  /**
   * Get the organization ID to use, prioritizing saved selection if valid
   * @param {Array} orgs - Array of organization objects with CustomerId property
   * @returns {string|null} The organization ID to use, or null if no orgs available
   */
  getOrganizationToUse: function (orgs) {
    if (!orgs || !Array.isArray(orgs) || orgs.length === 0) {
      return null;
    }

    // Try to restore saved organization selection
    var savedOrgId = this.getSavedOrganization();
    var selectedOrgId = null;

    if (savedOrgId && this.isValidOrganizationId(savedOrgId, orgs)) {
      // Use saved organization if it exists in the list
      selectedOrgId = savedOrgId;
    } else {
      // Fall back to first organization
      selectedOrgId = String(orgs[0].CustomerId);
    }

    return selectedOrgId;
  },
};

// =====================================================================
// Unified date display format (project-wide).
//   Date only / midnight -> dd-MMM-yyyy         e.g. 15-Jan-2026
//   With a real time      -> dd-MMM-yyyy HH:mm   e.g. 15-Jan-2026 14:30
// DISPLAY ONLY. Parses the ISO/SQL string components directly (no
// `new Date()`), so the stored date/time is shown verbatim with no
// timezone shift. Non-date values are returned unchanged.
// =====================================================================
window.gracFormatDisplayDate = function (value) {
  if (value === null || value === undefined || value === "") return value;
  var s = String(value).trim();
  var m = s.match(/^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?$/);
  if (!m) return value;
  var mo = parseInt(m[2], 10);
  if (mo < 1 || mo > 12) return value;
  var months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
  var out = m[3] + "-" + months[mo - 1] + "-" + m[1];
  var hh = m[4], mi = m[5], ss = m[6];
  if (hh !== undefined && !(hh === "00" && mi === "00" && (ss === undefined || ss === "00"))) {
    out += " " + hh + ":" + mi;
  }
  return out;
};
// Format a JS Date object to the same date-only shape (dd-MMM-yyyy).
window.gracFormatDisplayDateObj = function (d) {
  if (!(d instanceof Date) || isNaN(d)) return "";
  var months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
  return String(d.getDate()).padStart(2, "0") + "-" + months[d.getMonth()] + "-" + d.getFullYear();
};
// Date-only display (dd-MMM-yyyy) from a raw value, ignoring any time part.
// Use for sites that previously called toLocaleDateString() (date only).
window.gracFormatDateOnly = function (value) {
  if (value === null || value === undefined || value === "") return "";
  var s = String(value).trim();
  var datePart = s.length >= 10 ? s.slice(0, 10) : s;
  var out = window.gracFormatDisplayDate(datePart);
  return out === datePart ? s : out;
};
