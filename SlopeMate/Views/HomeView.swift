//
//  ContentView.swift
//  SlopeMate
//
//  Created by 박지호 on 12/1/25.
//

import Observation
import SwiftUI

struct HomeView: View {
    @State private var dateManager = DateManager()
    @State private var weatherStore = ResortWeatherStore()
    @State private var showingDatePicker = false

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    DateHeaderView(dateManager: dateManager) {
                        showingDatePicker = true
                    }

                    if weatherStore.isLoading && weatherStore.weatherByResort.isEmpty {
                        ProgressView("날씨를 불러오는 중입니다…")
                            .frame(maxWidth: .infinity)
                    } else if !weatherStore.weatherByResort.isEmpty {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(resorts) { resort in
                                NavigationLink {
                                    ResortDetailView(
                                        resort: resort,
                                        weather: weatherStore.weatherByResort[resort.id]
                                    )
                                } label: {
                                    ResortCardView(
                                        resort: resort,
                                        weather: weatherStore.weatherByResort[resort.id]
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else if !weatherStore.isLoading {
                        ContentUnavailableView(
                            "날씨 정보를 불러올 수 없습니다",
                            systemImage: "exclamationmark.triangle",
                            description: Text(weatherStore.alertMessage ?? "해당 날짜의 날씨 정보가 없습니다.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("SlopeMate")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await weatherStore.loadWeather(for: resorts, on: dateManager.selectedDate) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(weatherStore.isLoading)
                    .accessibilityLabel("날씨 새로고침")
                }
            }
        }
        .sheet(isPresented: $showingDatePicker) {
            DatePickerSheet(dateManager: dateManager)
                .presentationDetents([.fraction(0.75), .large])
                .presentationDragIndicator(.visible)
        }
        .task {
            await weatherStore.loadWeather(for: resorts, on: dateManager.selectedDate)
        }
        .onChange(of: dateManager.selectedDate) { _, newDate in
            Task { await weatherStore.loadWeather(for: resorts, on: newDate) }
        }
        .refreshable {
            await weatherStore.loadWeather(for: resorts, on: dateManager.selectedDate)
        }
        .alert("네트워크 오류", isPresented: Binding(
            get: { weatherStore.alertMessage != nil },
            set: { if !$0 { weatherStore.alertMessage = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(weatherStore.alertMessage ?? "알 수 없는 오류가 발생했습니다.")
        }
    }
}

private struct DateHeaderView: View {
    @Bindable var dateManager: DateManager
    var onChangeRequested: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("방문 날짜")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(dateManager.formattedSelectedDate)
                        .font(.title3)
                        .fontWeight(.semibold)
                }
                Spacer()
                
                VStack(alignment: .trailing) {
                    Button {
                        dateManager.resetToToday()
                    } label: {
                        Text("오늘")
                    }
                    .buttonStyle(.bordered)

                    HStack(spacing: 8) {
                        Button {
                            dateManager.move(by: -1)
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.bordered)
                                                
                        Button {
                            dateManager.move(by: 1)
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            Button {
                onChangeRequested()
            } label: {
                Label("다른 날짜 선택", systemImage: "calendar")
                    .font(.subheadline)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct ResortCardView: View {
    let resort: Resort
    let weather: WeatherDisplayModel?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 상단: 리조트 이름 + 날씨 아이콘
            HStack(alignment: .top) {
                Text(resort.name)
                    .font(.headline)
                
                Spacer()
                
                WeatherIconView(weather: weather, size: 24)
            }
            
            // 운영 시간
            Text(resort.operatingHours.shortSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            // 날씨 정보
            if let weather {
                HStack {
                    VStack(alignment: .leading) {
                        Text(weather.description)
                            .font(.subheadline)

                        Text("\(weather.temperature.formatted(.number.precision(.fractionLength(0))))°")
                            .font(.system(size: 32, weight: .semibold, design: .rounded))
                            .foregroundStyle(weather.iconColor)
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .leading, spacing: 10) {
                        Label {
                            Text("\(weather.windSpeed.formatted(.number.precision(.fractionLength(0))))m/s")
                        } icon: {
                            Image(systemName: "wind")
                        }
                        .foregroundStyle(weather.windSpeed >= 10 ? .orange : .secondary)
                        
                        Label("\(weather.humidity)%", systemImage: "humidity")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct DatePickerSheet: View {
    @Bindable var dateManager: DateManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    DatePicker(
                        "방문 날짜",
                        selection: $dateManager.selectedDate,
                        in: dateManager.minDate...dateManager.maxDate,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .environment(\.locale, Locale(identifier: "ko_KR"))
                    .environment(\.timeZone, TimeZone(identifier: "Asia/Seoul") ?? .current)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.top, 8)
                }
                .padding()
            }
            .navigationTitle("날짜 선택")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
    }
}

#if DEBUG
#Preview {
    HomeView()
}

#Preview("Date Header View") {
    DateHeaderView(dateManager: DateManager()) {}
        .padding()
        .background(Color(.systemGroupedBackground))
}

#Preview("Resort Card View") {
    ResortCardView(resort: .preview, weather: .preview)
        .padding()
        .background(Color(.systemGroupedBackground))
}

#Preview("Date Picker Sheet") {
    DatePickerSheet(dateManager: DateManager())
}
#endif
