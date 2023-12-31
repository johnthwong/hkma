# All datasets are pulled from APIs. 
# Thus, the outputs can be fully replicated in R,
# provided that the following libraries are installed.

library(tidyverse)
library(zoo)
library(lubridate)
library(jsonlite)
library(glmnet)
library(ggthemes)
library(gridExtra)

# Introduction ----

# This is an exercise of (i) understanding Hong Kong's monetary base and
# (ii) predicting interest rates with central bank operations.
# The prediction model is not a nowcast per se, 
# though it can be used with the central bank's forecasted operations
# to generate a prediction of interest rates for the upcoming 4 days.

# Data manipulation ----

## US data - NYFed ----

# As Hong Kong's money market is largely influenced by the US's,
# the following dataset from the NYFed is used to gather US interest rates.
# The specific rate is the OBFR (which measures unsecured borrowing costs).
# The original data is daily.
# The following code is used to retain only end-of-month observations, 
# so as to match the rest of the datasets to be used.
data_obfr <- fromJSON("https://markets.newyorkfed.org/api/rates/unsecured/obfr/last/999.json")$refRates %>%
  select(effectiveDate, percentRate) %>%
  mutate(
    date = as.Date(effectiveDate, "%Y-%m-%d") %>% ymd(),
    ym = as.yearmon(date) %>% as.Date(),
    obfr = percentRate
  ) %>%
  group_by(ym) %>%
  arrange(desc(date)) %>%
  filter(row_number()==1) %>%
  ungroup() %>%
  select(obfr, ym)


## Hong Kong data - Hong Kong Monetary Authority (the central bank) ----

# data_balancesheet tracks the central bank's deposits by type.
data_balancesheet <- fromJSON("https://api.hkma.gov.hk/public/market-data-and-statistics/monthly-statistical-bulletin/ef-fc-resv-assets/ef-bal-sheet-abridged")$result$records

# data_moneysupply tracks Hong Kong's aggregate supply of money.
data_moneysupply <- fromJSON("https://api.hkma.gov.hk/public/market-data-and-statistics/monthly-statistical-bulletin/money/supply-components-all")$result$records

# the following two datasets tracks money supply by local and foreign currencies.
data_moneysupply_hkd <- fromJSON("https://api.hkma.gov.hk/public/market-data-and-statistics/monthly-statistical-bulletin/money/supply-components-hkd")$result$records
data_moneysupply_fc <- fromJSON("https://api.hkma.gov.hk/public/market-data-and-statistics/monthly-statistical-bulletin/money/supply-components-fc")$result$records

# data_rates tracks interest rates for various borrowing horizons.
data_rates <- fromJSON("https://api.hkma.gov.hk/public/market-data-and-statistics/monthly-statistical-bulletin/er-ir/hk-interbank-ir-endperiod?segment=hibor.fixing")$result$records

# data_operations tracks the central bank's operations in the money market.
data_operations <- fromJSON("https://api.hkma.gov.hk/public/market-data-and-statistics/monthly-statistical-bulletin/monetary-operation/market-operation-periodaverage")$result$records

# data_forwards tracks the prices of currency forwards. 
# This will not be highly relevant to this abridged exercist.
data_forwards <- fromJSON("https://api.hkma.gov.hk/public/market-data-and-statistics/monthly-statistical-bulletin/er-ir/hkd-fer-endperiod")$result$records
data_honia <- fromJSON("https://api.hkma.gov.hk/public/market-data-and-statistics/monthly-statistical-bulletin/er-ir/hk-interbank-ir-endperiod?segment=honia")$result$records %>%
  mutate(
    honia_overnight = ir_overnight,
    ir_overnight = NULL
  )

## Hong Kong data - Census and Statistics Department ----

# data_unemp_original is Hong Kong's monthly unemployment data.
# The original dataset includes moments of the underlying statistics, 
# which will be removed with the following code.
data_unemp_original <- fromJSON("https://www.censtatd.gov.hk/api/get.php?id=210-06101&lang=en&param=N4KABGBEDGBukC4yghSBlAogDUWA2uKmgLKQA0RxkAYpFWALpEC+laAzvEiqpADJ0khYmgBKAQwDuAfQDSMgIwATAA4zVAUwBOMgHYUGaAJoB7Y0rUyApDI71ijdn0EAFMXhGjIkgC6bLdVsDBicGSABVD2EjKD8AlSD9B1Qw6kwyGNE46XlAjR1k0Oc0CIARTE9Yn1yFRILdEMcSqHLogmr4-OCUiDS+dABBKKrsmv9uoubwiMqs70lZOqstRt6mVmdIVYBLU2U8Xk5fCW1fPEhFAE4ADgBWAAYAZhS2Ikgdg6RIACZFB4AtA8AGz-RSGNAAGwkegA5hdNCEWEA")$dataSet
# SAUR = seasonally adjusted unemployment rate
data_unemp <- data_unemp_original %>% filter(freq == "M3M" & svDesc == "(%)" & sv == "SAUR") %>%
  select(period, figure) %>%
  mutate(
    ym = as.yearmon(period, "%Y%m") %>% as.Date(),
    period = NULL,
    unemp = as.numeric(figure),
    figure = NULL
  )

# data_cpi_original is Hong Kong's consumer price data. 
# Similar data structure to above.
data_cpi_original <- fromJSON("https://www.censtatd.gov.hk/api/get.php?id=510-60001&lang=en&param=N4KABGBEDGBukC4zAL4BpxQM7yaCEkAwkQPpECypAjAJwBMADImANqYFQBKAhgO40AJgAdSAS0EAPUgDtIGToQoB7KtRGkApKSzyOBSAE1lhoaO279AXQUGAQuTUNmSdou78z4qbL3vIKmoaFn6KRiZeIda2hGSUNM4sbmG8AuqiEtJyMQaBkTqhnOGm6VoF0fqQAIKOCUxJ+oSpXpm+OUqq+brtUMYlweWcVpjomJDCAKYATmLKgiz4BlgALjxTyyyQdADsACyM25AjtpASmwCs1IwAtABsjA-UoZAANjwyAOabE3IgKEA")$dataSet

data_cpi <- data_cpi_original %>% filter(freq == "M" & sv == "CC_CM_1920" & svDesc == "Index") %>%
  select(period, figure) %>%
  mutate(
    ym = as.yearmon(period, "%Y%m") %>% as.Date(),
    period = NULL,
    cpi = as.numeric(figure),
    figure = NULL
  ) %>%
  na.omit()

## Merging everything ----
df_0 <- merge(data_balancesheet, data_moneysupply, by = "end_of_month") %>%
  merge(data_rates, by = "end_of_month") %>%
  merge(data_operations, by = "end_of_month") %>%
  merge(data_forwards, by = "end_of_month") %>%
  merge(data_honia, by = "end_of_month") %>%
  # The following mutation converts currency prices to a standard convention.
  mutate(across(all_of(contains("fer")) & !contains("spot"),
                ~ .x/100 + hkd_fer_spot,
                .names = "{.col}_rate"
  )) %>%
  mutate(
    ym = as.yearmon(end_of_month, "%Y-%m") %>% as.Date()
  ) %>%
  merge(data_obfr, by = "ym") %>%
  merge(data_unemp, by = "ym") %>%
  merge(data_cpi, by = "ym")

# df_4 retains only datasets from the central bank for a longer sample horizon.
df_4 <- merge(data_balancesheet, data_moneysupply, by = "end_of_month") %>%
  merge(data_rates, by = "end_of_month") %>%
  merge(data_operations, by = "end_of_month") %>%
  merge(data_forwards, by = "end_of_month") %>%
  merge(data_honia, by = "end_of_month") %>%
  mutate(across(all_of(contains("fer")) & !contains("spot"),
                ~ .x/100 + hkd_fer_spot,
                .names = "{.col}_rate"
  )) %>%
  mutate(
    ym = as.yearmon(end_of_month, "%Y-%m") %>% as.Date()
  ) %>%
  relocate(ym)


# Data Visualization on Reserves ----

## Plot shows total deposits at the central bank ----
# versus deposits provided by commercial banks (aka "Aggregate Balance").
ggplot(df_4, aes(x=ym)) +
  geom_line(aes(y=liab_banking_system_bal, color = "Aggregate Balance"))  +
  geom_line(aes(y = assets_total, color = "HKMA Total Assets")) +
  theme_bw()+
  scale_colour_calc()
# Takeaway: "aggregate balance" is not so aggregate after all.

## Plot shows deposits in the banking system, by deposit type ----
ggplot(df_4, aes(x=ym)) +
  geom_line(aes(y = demand_deposits_with_lb, color = "Demand Deposits")) +
  geom_line(aes(y = savings_deposits_with_lb, color = "Savings Deposits")) +
  geom_line(aes(y = time_deposits_with_lb, color = "Time Deposits"))+
  scale_colour_calc()
# Takeaway: time deposits--which are hardest to withdraw--have been rising.

## Plot shows deviation between Hong Kong and US rates ----
# (with the average as y-intercept.)
df_0 <- df_0 %>% mutate(diff_overnight = abs(obfr - ir_overnight))
ggplot(df_0, aes(x=ym)) +
  geom_line(aes(y=diff_overnight), color = "Red")+
  geom_hline(yintercept = mean(df_0$diff_overnight))


## Plot: HKMA's Balance Sheet ----

# The following chunks of code will result in a graph of the central bank's
# balance sheet (i.e., assets, liabilities, and equity), by major line items,
# over time.

# This code mutates the capital side of the balance sheet into negative values,
# for visualization purposes.
df_8 <- data_balancesheet %>%
  mutate(
    ym = as.yearmon(end_of_month, "%Y-%m") %>% as.Date(),
    end_of_month = NULL
  ) %>% 
  relocate(ym) %>%
  select(-unaudited_figures, -contains("total")) %>%
  mutate(
    across(all_of(contains(c("liab", "equity"))),
           ~ .x*-1,
           .names = "{.col}")) 

df_8[is.na(df_8)] <- 0

# This code pivots the dataframe into a longer structure (for ggplot) and
# subsequently replaces each line item's column name with a proper label.
df_8 <- df_8 %>%
  mutate(
    liab_misc = liab_gov_iss_curr_notes + liab_other + liab_pla_bank_oth_fin_instit + liab_subsidiaries) %>%
  select(-liab_gov_iss_curr_notes, -liab_other, - liab_pla_bank_oth_fin_instit, - liab_subsidiaries, - liab_other_instit) %>%
  gather(key = "line_item", value = "value", - ym) %>%
  mutate(line_item = case_when(
    line_item == "assets_fc" ~ "Assets: foreign",
    line_item == "assets_hkd" ~ "Assets: HKD",
    line_item == "fund_equity" ~ "Equity",
    line_item == "liab_banking_system_bal" ~ "Liability: Aggregate Balance",
    line_item == "liab_cert_of_indebt" ~ "Liability: Printed Currency",
    line_item == "liab_ef_bills_notes_iss" ~ "Liability: HKMA's Bills & Notes",
    line_item == "liab_fiscal_resv" ~ "Liability: Government's reserves",
    line_item == "liab_govfunds_statubodies" ~ "Liability: Statutory Funds",
    line_item == "liab_misc" ~ "Misc. Liabilities"
  ))

# The plot:
plot_ma_balance <- df_8 %>% ggplot(aes(x = ym, y = value/1e+06, fill = line_item))+
  geom_area() +
  labs(
    title = "HKMA Balance Sheet",
    y = "HK$ trillions",
    x = "",
    fill = "Line Items"
  ) +
  # The theme is chosen to mimic a Microsoft Office-esque style, 
  # for publishing purposes.
  # theme_bw() +
  # scale_fill_calc() +
  theme(
    legend.position = "right",
    text = element_text(size = 12),
    title = element_text(size=14, face = 'bold'),
    legend.text=element_text(size=12),
    legend.title=element_text(size=12, face = 'bold')
  ) +
  scale_y_continuous(labels = abs)

## Plot: money supply by currencies ----

# Plot shows money supply in Hong Kong.
ggplot(df_4, aes(x=ym)) +
  geom_line(aes(y = m3_supply))
# Takeaway: despite fears, it has not shrunk much in recent years.

# The following chunks of code visualizes Hong Kong's money supply, by currency.

# This chunk merges the two datasets on money supply and pivots them longer.
df_9 <- merge(data_moneysupply_hkd, data_moneysupply_fc, by = "end_of_month") %>%
  mutate(
    ym = as.yearmon(end_of_month, "%Y-%m") %>% as.Date(),
    end_of_month = NULL
  ) %>%
  select(ym, m3_supply.x, m3_supply.y) %>%
  rename(
    HKD = m3_supply.x,
    Foreign = m3_supply.y
  ) %>%
  gather(key = "currency", value = "dollars", - ym) 

# Plot:
plot_base_by_fx <- df_9 %>% ggplot(aes(x = ym, y = dollars/1e+06, fill = currency)) +
  geom_area()+
  labs(
    fill = "Legend",
    x = "",
    title = "Hong Kong's Monetary Base, by currency",
    y = "HK$ trillions"
  ) +
  # theme_bw() +
  # scale_fill_calc() +
  theme(
    legend.position = "bottom",
    text = element_text(size = 12),
    title = element_text(size=14, face = 'bold'),
    legend.text=element_text(size=12),
    legend.title=element_text(size=12, face = 'bold')
  ) 
# Takeaway: only half the money in Hong Kong is denoted in the local currency.
# This is relevant as the local currency needs to be defended by 
# the central bank's reserves of USD.
# This shows that only about half of the money supply needs to be defended.

# The following code calculates 
# the size of commercial bank deposits at the central bank,
# in the context of the total money supply.
df_4 %>% mutate(aggregate_balance_to_m3 = liab_banking_system_bal/m3_supply) %>%
  select(aggregate_balance_to_m3) %>% pull() %>% range()
# Takeaway: it never exceeds 3% of the total money.


## Plot: Hong Kong's monetary base, net HKMA and Aggregate Balance ----

# The following chunks visualizes how much of the local currency is secured by
# the central bank's reserves (i.e., can be converted to USD).

# This code combines data on the central bank's balance sheet with data on
# money supply that is denoted in the local currency.
# The code also pivots the data longer and replaces column names with proper labels.
df_6 <- merge(data_balancesheet, data_moneysupply_hkd, by = "end_of_month") %>%
  merge(data_moneysupply_fc, by = "end_of_month") %>%
  mutate(
    ym = as.yearmon(end_of_month, "%Y-%m") %>% as.Date()
  ) %>%
  relocate(ym) %>% 
  mutate(
    assets_net_banking_system_bal = assets_total - liab_banking_system_bal,
    m3_supply_net_hkma = m3_supply.x - assets_total
  ) %>%
  select(ym, liab_banking_system_bal, assets_net_banking_system_bal, 
         m3_supply_net_hkma, m3_supply.y) %>%
  gather(key = "item", value = "millions", - ym) %>%
  mutate(
         item = case_when(
           item == "liab_banking_system_bal" ~ "Aggregate Balance (AB)",
           item == "assets_net_banking_system_bal" ~ "HKMA net AB",
           item == "m3_supply_net_hkma" ~ "M3 HKD, net HKMA and AB",
           item == "m3_supply.y" ~ "M3 foreign currency"
         ),
         # item = fct_reorder(item, millions, .desc = TRUE),
         item = factor(item, levels = c("Aggregate Balance (AB)", 
                                        "HKMA net AB",
                                        "M3 HKD, net HKMA and AB",
                                        "M3 foreign currency"))
  )

# Plot: 
plot_base_net_ma <- df_6 %>% ggplot(aes(x = ym, y = millions/1e+06, fill = item)) +
  geom_area() +
  labs(
    fill = "Legend",
    x = "",
    title = "Hong Kong's HKD Monetary Base, Covered vs. Uncovered by HKMA",
    y = "HK$ trillions"
  ) +
  # theme_bw() +
  # scale_fill_calc() +
  theme(
    legend.position = "right",
    text = element_text(size = 12),
    title = element_text(size=14, face = 'bold'),
    legend.text=element_text(size=12),
    legend.title=element_text(size=12, face = 'bold')
  ) 

# Takeaway 1: commercial bank deposits at the central bank 
# make up an insignificant amount of total reserves.
# Takeaway 2: the central bank has the capacity 
# to maintain the local currency's value 
# provided that no more than about half is converted.

## final output ----
grid.arrange(plot_ma_balance, plot_base_net_ma, nrow = 2)

## Statistical test on which line item predicts money supply ----
merge(data_moneysupply_fc, data_balancesheet, by = "end_of_month") %>% 
  lm(data = ., m3_supply ~ liab_banking_system_bal) %>%
  summary()

merge(data_moneysupply_fc, data_balancesheet, by = "end_of_month") %>% 
  lm(data = ., m3_supply ~ fund_equity) %>%
  summary()

# Takeaway: it is not aggregate balance that co-moves money supply, but rather 
# the HKMA's own equity.


## Plot: Aggregate Balance (daily) ----
data_daily_liquidity <- fromJSON("https://api.hkma.gov.hk/public/market-data-and-statistics/daily-monetary-statistics/daily-figures-interbank-liquidity?pagesize=1000&offset=0")$result$records %>%
  rbind(
    fromJSON("https://api.hkma.gov.hk/public/market-data-and-statistics/daily-monetary-statistics/daily-figures-interbank-liquidity?pagesize=1000&offset=1000")$result$records
  ) %>%
  mutate(
    date = as.Date(end_of_date, "%Y-%m-%d"),
    end_of_date = NULL
  ) %>%
  relocate(date)

ggplot(data_daily_liquidity, aes(x = date)) +
  geom_line(aes(y = closing_balance/1e+06)) +
  labs(
    title = "Aggregate Balance",
    y = "HK$ trillions",
    x = ""
  ) +
  theme_bw() +
  theme(
    text = element_text(size = 20, family = "Arial Narrow Bold")
  )


## Plot: Comparing banking system balance to aggregate balance ----
grid.arrange(
  ggplot(df_4, aes(x = ym, y = liab_banking_system_bal)) +
    geom_line(),
  ggplot(data_daily_liquidity %>% filter(date >= "2016-04-01"), aes(x = date, y = closing_balance)) + 
    geom_line(),
  ncol = 2
)
# This confirms that the monthly dataset tracks the same thing as the daily one.



# Statistical Models for Predicting the Local Interest Rate ----

## AR(1): local rate ~ local rate last month ----
lm_0 <- lm(ir_overnight ~lag(ir_overnight), df_0)
summary(lm_0) 

## local rate (unsecured) ~ US rate (unsecured) + local money supply ----
lm_1 <- lm(ir_overnight ~ obfr + m3_supply, df_0)
summary(lm_1)

# Plot of model performance
ggplot(df_0, aes(x=ym)) +
  geom_line(aes(y=ir_overnight), color = "Red") +
  geom_line(aes(y=obfr))


## local rate ~ US rate last month + local money supply last month ----
lm_2 <- lm(lead(ir_overnight, n = 2) ~ obfr + m3_supply, df_0)
summary(lm_2)

# Plot of model performance
ggplot(df_0, aes(x=ym)) +
  geom_line(aes(y=lead(ir_overnight, n = 0)), color = "Red") +
  geom_line(aes(y=obfr))

## local rate ~ US rate ----
lm_3 <- lm(ir_overnight ~ obfr, df_0)
summary(lm_3)

## local rate (1-week horizon) ~ US rate (overnight) + spot hkd/usd price ----
# + 1-week forward hkd/usd price
lm_4 <- lm(ir_1w ~ obfr + hkd_fer_spot + hkd_fer_1w_rate, df_0)
summary(lm_4)
# The spot exchange rate is the "summary" of fundamentals and other things, 
# part of which drives interest rate differentials.
# But given that interest rate differentials also drive spot exchange rate,
# not much is learned here.

## local rate ~ US rate 1 year ago + hkd/usd price 1 year ago ----
# + 1-year forward hkd/usd price 1 year ago
lm_5 <- lm(lead(ir_overnight, n = 12) ~ obfr + hkd_fer_spot + hkd_fer_12m_rate, df_0)
summary(lm_5)

## local rate ~ 1-year forward hkd/usd price 1 year ago ----
lm_6 <- lm(lead(ir_overnight, n = 12) ~ hkd_fer_12m_rate, df_0)
summary(lm_6)
# Takeaway: long-term currency forward contracts are not very predictive of future rates.


## local rate ~ US rate + central bank balance sheet + operations + macroecon ----

df_3 <- df_0 %>% select(ym, assets_total, contains("liab") 
                        & !contains(c("total", "other", "subsidiaries")), fund_equity,
                        m3_supply, discount_window_activities_lending,
                        obfr, ir_overnight, unemp, cpi
) 

lm_7 <- lm(data = df_3, ir_overnight ~ . - ym)
summary(lm_7)
lm_7_pred <- predict(lm_7)


## LASSO: local rate ~ US rate + central bank balance sheet + operations + macroecon ----

# Split the dataframe into y and X components for glmnet functions
df_3_x <- model.matrix(data = df_3, ir_overnight ~ . - ym)[,-1]
df_3_y <- df_3 %>% pull(ir_overnight)

# Train the model
lasso_1 <- glmnet(df_3_x, df_3_y, alpha = 1, lambda = 1e-1, family = "gaussian")

# Use cross-validation to set the regularization parameter.
set.seed(1)
lasso_1_cv <- cv.glmnet(df_3_x, df_3_y, alpha = 1, nfolds = 3)
plot(lasso_1_cv)
best_lambda_1 <- lasso_1_cv$lambda.min

# Output: coefficients
predict(lasso_1, type = "coefficients", s = best_lambda_1)
# Takeaway: the most predictive variables appear to be the central bank's 
# total reserves, issuance of USD-denominated debt, and lending,
# in addition to US interest rates and unemployment.
# These determinants make a lot of sense. Though unemployment would likely be
# difficult to incorporate into a real forecast.

# Output: predicted values
lasso_1_pred <- predict(lasso_1, type = "response", s = best_lambda_1, newx = df_3_x)

# R2
1 - mean((lasso_1_pred - df_3_y)^2)/var(df_3_y)

### Plot: OLS vs LASSO ----

ggplot(df_3, aes(x=ym))+
  geom_line(aes(y=lasso_1_pred), color = "Blue")+
  geom_line(aes(y=ir_overnight), color = "Red")+
  geom_line(aes(y=lm_7_pred), color = "Purple")
# Takeaway: the LASSO model's predictions shows less variance than 
# that of the OLS model.

# Out-of-sample performance: OLS vs LASSO: ----

# Set the out-of-sample cutoff as observations before:
cutoff <- "2021-07-01"

#### LASSO ----

# Create training sample with the outcome and predictors as separate matricies
df_3_x_train <- model.matrix(data = df_3 %>% filter(ym < as.Date(cutoff)), ir_overnight ~ . - ym)[,-1]
df_3_y_train <- df_3 %>% filter(ym < as.Date(cutoff)) %>% pull(ir_overnight)

# Same for test sample:
df_3_x_test <- model.matrix(data = df_3 %>% filter(ym >= as.Date(cutoff)), ir_overnight ~ . - ym)[,-1]
df_3_y_test <- df_3 %>% filter(ym >= as.Date(cutoff)) %>% pull(ir_overnight)

# Use cross-validation to set the regularization parameter, lambda
set.seed(1)
lasso_1_train_cv <- cv.glmnet(df_3_x_train, df_3_y_train, alpha = 1, nfolds = 3)
plot(lasso_1_train_cv)
# Mean-squared error is lowest when lambda is set 
# between exp(-4) - exp(-3).
# Extract best lambda:
best_lambda_1_train <- lasso_1_train_cv$lambda.min


# Train the model
lasso_1_train<- glmnet(df_3_x_train, df_3_y_train, alpha = 1, lambda = best_lambda_1_train, family = "gaussian")
predict(lasso_1_train, type = "coefficients")

# Get the prediction
lasso_1_test_pred <- predict(lasso_1_train, s = best_lambda_1_train, newx = df_3_x_test)

# Calculate out-of-sample R2
# The mean-squared error, i.e., sum of squared residuals, is calculated by hand:
# R2 = 1 - MSE
lasso_1_test_r2 <- 1 - mean((lasso_1_test_pred - df_3_y_test)^2)/var(df_3_y_test)
lasso_1_test_r2
# Pretty bad out-of-sample accuracy. But bad is relative (to the OLS performance).

#### OLS ----

# Same as above:
# train the model
lm_7_train <- lm(data = df_3 %>% filter(ym < as.Date(cutoff)), ir_overnight ~ . - ym)
# get the prediction
lm_7_test_pred <- predict(lm_7_train, newdata = df_3 %>% filter(ym >= as.Date(cutoff)))
# out-of-sample R2
lm_7_test_r2<- 1 - mean((lm_7_test_pred - df_3_y_test)^2)/var(df_3_y_test)
lm_7_test_r2

c(OLS = lm_7_test_r2, LASSO = lasso_1_test_r2)
# LASSO-estimated model performs better than OLS-estimated one. 

#### Plot ----
ggplot(df_3 %>% filter(ym >= as.Date(cutoff)), aes(x=ym))+
  geom_line(aes(y=lasso_1_test_pred), color = "Blue")+
  geom_line(aes(y=ir_overnight), color = "Red") +
  geom_line(aes(y=lm_7_test_pred), color = "Purple")
# The relatively superior accuracy can be attributed to the LASSO model's
# lower variance.

